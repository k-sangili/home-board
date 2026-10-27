import Foundation
import HomeKit
import Observation

struct HomeDevice: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        case lock, garage, thermostat, sensor, light
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    enum Security: Equatable {
        case secure, open, moving, jammed, unknown
    }

    let id: String
    var name: String
    var room: String
    var kind: Kind
    /// Locks and garage doors.
    var security: Security?
    /// Lights.
    var isOn: Bool?
    /// Thermostats and sensors, in °C (HomeKit's unit).
    var temperature: Double?
    var target: Double?
    var activity: String?
    var isReachable = true

    var isDoor: Bool { kind == .lock || kind == .garage }
}

struct HomeScene: Identifiable {
    let id: String
    let name: String
}

struct HomeCamera: Identifiable {
    let id: String
    let name: String
    let room: String
}

/// HomeKit, flattened into what the board shows: doors, climate, lights, scenes and cameras.
/// The Apple TV must be signed in to the iCloud account that owns the home.
@MainActor
@Observable
final class HomeStore: NSObject {
    enum Status: Equatable {
        case loading, ready, demo, noHome, notAuthorized
    }

    private(set) var status: Status = .loading
    private(set) var homeName = ""
    private(set) var devices: [HomeDevice] = []
    private(set) var scenes: [HomeScene] = []
    private(set) var cameras: [HomeCamera] = []
    /// When each lock or garage door was first seen not secure (for "open for 20 min").
    private(set) var insecureSince: [String: Date] = [:]

    let config: HomeConfig
    @ObservationIgnored private var manager: HMHomeManager?
    @ObservationIgnored private var home: HMHome?
    @ObservationIgnored private var services: [String: HMService] = [:]
    @ObservationIgnored private var profiles: [String: HMCameraProfile] = [:]

    init(config: HomeConfig = .load()) {
        self.config = config
    }

    func start() {
        guard manager == nil, status != .demo else { return }
        if Launch.isDemo {
            loadDemo()
            return
        }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
    }

    var doors: [HomeDevice] { devices.filter(\.isDoor) }
    var climate: [HomeDevice] { devices.filter { $0.kind == .thermostat || $0.kind == .sensor } }
    var lights: [HomeDevice] { devices.filter { $0.kind == .light } }

    func cameraProfile(for id: String) -> HMCameraProfile? { profiles[id] }

    // MARK: - Actions

    /// Locks/unlocks a lock, or closes/opens a garage door.
    func setSecure(_ device: HomeDevice, _ secure: Bool) async throws {
        if status == .demo {
            update(device.id) { $0.security = secure ? .secure : .open }
            return
        }
        let type = device.kind == .lock ? HMCharacteristicTypeTargetLockMechanismState : HMCharacteristicTypeTargetDoorState
        // Lock target: 1 = secured, 0 = unsecured. Garage target: 1 = closed, 0 = open.
        try await write(device, type, value: secure ? 1 : 0)
    }

    func toggle(_ light: HomeDevice) async throws {
        let on = !(light.isOn ?? false)
        if status == .demo {
            update(light.id) { $0.isOn = on }
            return
        }
        try await write(light, HMCharacteristicTypePowerState, value: on)
    }

    /// Nudges a thermostat's target by `delta` °C, staying inside the accessory's limits.
    func adjustTarget(_ device: HomeDevice, by delta: Double) async throws {
        guard let current = device.target else { return }
        if status == .demo {
            update(device.id) { $0.target = current + delta }
            return
        }
        guard let characteristic = characteristic(device, HMCharacteristicTypeTargetTemperature) else { return }
        var value = current + delta
        if let min = characteristic.metadata?.minimumValue?.doubleValue { value = max(value, min) }
        if let max = characteristic.metadata?.maximumValue?.doubleValue { value = min(value, max) }
        try await characteristic.writeValue(value)
        rebuild()
    }

    func run(_ scene: HomeScene) async throws {
        guard status != .demo, let home, let set = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == scene.id }) else { return }
        try await home.executeActionSet(set)
    }

    private func characteristic(_ device: HomeDevice, _ type: String) -> HMCharacteristic? {
        services[device.id]?.characteristics.first { $0.characteristicType == type }
    }

    private func write(_ device: HomeDevice, _ type: String, value: Any) async throws {
        guard let characteristic = characteristic(device, type) else { return }
        try await characteristic.writeValue(value)
        rebuild()
    }

    private func update(_ id: String, _ change: (inout HomeDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
        trackSecurity()
    }

    // MARK: - Reading HomeKit

    private static let watched: Set<String> = [
        HMCharacteristicTypeCurrentLockMechanismState, HMCharacteristicTypeCurrentDoorState,
        HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeTargetTemperature,
        HMCharacteristicTypeCurrentHeatingCooling, HMCharacteristicTypePowerState,
    ]

    private static let kinds: [String: HomeDevice.Kind] = [
        HMServiceTypeLockMechanism: .lock, HMServiceTypeGarageDoorOpener: .garage,
        HMServiceTypeThermostat: .thermostat, HMServiceTypeTemperatureSensor: .sensor,
        HMServiceTypeLightbulb: .light,
    ]

    private func selectHome() {
        guard let manager else { return }
        if !manager.authorizationStatus.contains(.authorized) {
            status = manager.authorizationStatus.contains(.determined) ? .notAuthorized : .loading
            return
        }
        let chosen = manager.homes.first { $0.name == config.homeName } ?? manager.homes.first
        guard let chosen else {
            status = .noHome
            return
        }
        home = chosen
        homeName = chosen.name
        chosen.delegate = self
        for accessory in chosen.accessories {
            accessory.delegate = self
            for service in accessory.services where Self.kinds[service.serviceType] != nil {
                for characteristic in service.characteristics where Self.watched.contains(characteristic.characteristicType) {
                    characteristic.enableNotification(true) { _ in }
                    characteristic.readValue { [weak self] _ in
                        Task { @MainActor in self?.rebuild() }
                    }
                }
            }
        }
        status = .ready
        rebuild()
    }

    private func rebuild() {
        guard let home else { return }
        let hidden = Set(config.hiddenAccessories ?? [])
        var services: [String: HMService] = [:]
        var devices: [HomeDevice] = []
        for accessory in home.accessories where !hidden.contains(accessory.name) {
            for service in accessory.services {
                guard let kind = Self.kinds[service.serviceType] else { continue }
                let id = service.uniqueIdentifier.uuidString
                services[id] = service
                let name = service.name.isEmpty ? accessory.name : service.name
                var device = HomeDevice(id: id, name: name, room: accessory.room?.name ?? "", kind: kind,
                                        isReachable: accessory.isReachable)
                func value(_ type: String) -> Any? {
                    service.characteristics.first { $0.characteristicType == type }?.value
                }
                switch kind {
                case .lock:
                    // 0 unsecured, 1 secured, 2 jammed, 3 unknown
                    switch (value(HMCharacteristicTypeCurrentLockMechanismState) as? NSNumber)?.intValue {
                    case 0: device.security = .open
                    case 1: device.security = .secure
                    case 2: device.security = .jammed
                    default: device.security = .unknown
                    }
                case .garage:
                    // 0 open, 1 closed, 2 opening, 3 closing, 4 stopped
                    switch (value(HMCharacteristicTypeCurrentDoorState) as? NSNumber)?.intValue {
                    case 0, 4: device.security = .open
                    case 1: device.security = .secure
                    case 2, 3: device.security = .moving
                    default: device.security = .unknown
                    }
                case .thermostat, .sensor:
                    device.temperature = (value(HMCharacteristicTypeCurrentTemperature) as? NSNumber)?.doubleValue
                    device.target = (value(HMCharacteristicTypeTargetTemperature) as? NSNumber)?.doubleValue
                    switch (value(HMCharacteristicTypeCurrentHeatingCooling) as? NSNumber)?.intValue {
                    case 1: device.activity = "Heating"
                    case 2: device.activity = "Cooling"
                    case 0: device.activity = "Idle"
                    default: break
                    }
                case .light:
                    device.isOn = (value(HMCharacteristicTypePowerState) as? NSNumber)?.boolValue
                }
                devices.append(device)
            }
        }
        self.services = services
        self.devices = devices.sorted { ($0.kind, $0.room, $0.name) < ($1.kind, $1.room, $1.name) }
        scenes = home.actionSets.map { HomeScene(id: $0.uniqueIdentifier.uuidString, name: $0.name) }
            .sorted { $0.name < $1.name }
        var profiles: [String: HMCameraProfile] = [:]
        cameras = home.accessories.filter { !hidden.contains($0.name) }.flatMap { accessory in
            (accessory.cameraProfiles ?? []).map { profile in
                let id = profile.uniqueIdentifier.uuidString
                profiles[id] = profile
                return HomeCamera(id: id, name: accessory.name, room: accessory.room?.name ?? "")
            }
        }
        self.profiles = profiles
        trackSecurity()
    }

    private func trackSecurity() {
        var since: [String: Date] = [:]
        for door in doors where door.security != .secure {
            since[door.id] = insecureSince[door.id] ?? .now
        }
        insecureSince = since
    }

    // MARK: - Demo

    private func loadDemo() {
        status = .demo
        homeName = "Demo Home"
        devices = [
            .init(id: "front", name: "Front Door", room: "Entry", kind: .lock, security: .secure),
            .init(id: "back", name: "Back Door", room: "Kitchen", kind: .lock, security: .open),
            .init(id: "garage", name: "Garage Door", room: "Garage", kind: .garage, security: .secure),
            .init(id: "thermo", name: "Thermostat", room: "Hallway", kind: .thermostat, temperature: 20.5, target: 21, activity: "Heating"),
            .init(id: "upstairs", name: "Upstairs", room: "Kids' Rooms", kind: .sensor, temperature: 19.5),
            .init(id: "kitchen", name: "Kitchen Lights", room: "Kitchen", kind: .light, isOn: true),
            .init(id: "living", name: "Living Room Lamp", room: "Living Room", kind: .light, isOn: true),
            .init(id: "porch", name: "Porch Light", room: "Outside", kind: .light, isOn: false),
            .init(id: "office", name: "Office", room: "Office", kind: .light, isOn: false),
        ]
        scenes = ["Good Morning", "Movie Night", "Goodnight"].map { HomeScene(id: $0, name: $0) }
        cameras = [
            HomeCamera(id: "doorbell", name: "Doorbell", room: "Entry"),
            HomeCamera(id: "driveway", name: "Driveway", room: "Outside"),
            HomeCamera(id: "backyard", name: "Backyard", room: "Outside"),
        ]
        insecureSince = ["back": Date.now.addingTimeInterval(-25 * 60)]
    }
}

// MARK: - Delegates (HomeKit calls these on the main queue)

extension HomeStore: HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        MainActor.assumeIsolated { selectHome() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        MainActor.assumeIsolated { selectHome() }
    }

    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        MainActor.assumeIsolated { selectHome() }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        MainActor.assumeIsolated { rebuild() }
    }

    nonisolated func home(_ home: HMHome, didAdd actionSet: HMActionSet) {
        MainActor.assumeIsolated { rebuild() }
    }

    nonisolated func home(_ home: HMHome, didRemove actionSet: HMActionSet) {
        MainActor.assumeIsolated { rebuild() }
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        MainActor.assumeIsolated { rebuild() }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        MainActor.assumeIsolated { rebuild() }
    }
}
