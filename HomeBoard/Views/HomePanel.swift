import SwiftUI

/// Doors, climate, lights and scenes. Locking and closing happen straight away; unlocking and
/// opening ask first, since anyone in the room can pick up the remote.
struct HomePanel: View {
    @Environment(HomeStore.self) private var home
    let now: Date
    @State private var confirming: HomeDevice?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PanelTitle(text: home.homeName.isEmpty ? "Home" : home.homeName, symbol: "house.fill")
                Spacer()
                if let problem {
                    Text(problem).font(Theme.font(16, .semibold)).foregroundStyle(Theme.test).lineLimit(1)
                }
            }
            switch home.status {
            case .loading:
                message("Connecting to HomeKit…")
            case .notAuthorized:
                message("Allow HomeBoard to use your home: Settings → Apps → HomeBoard → Home.")
            case .noHome:
                message("No HomeKit home found. Sign this Apple TV in to the iCloud account that owns your home.")
            case .ready, .demo:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !home.doors.isEmpty { doors }
                        if !home.climate.isEmpty { climate }
                        lights
                        if !home.scenes.isEmpty { scenes }
                    }
                    .padding(6)
                }
                .scrollClipDisabled()
            }
            Spacer(minLength: 0)
        }
        .panelStyle()
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { device in
            Button(device.kind == .garage ? "Open" : "Unlock", role: .destructive) { perform { try await home.setSecure(device, false) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var confirmTitle: String {
        guard let confirming else { return "" }
        return confirming.kind == .garage ? "Open \(confirming.name)?" : "Unlock \(confirming.name)?"
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Theme.font(20, .medium)).foregroundStyle(Theme.secondary)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    private var doors: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(home.doors) { door in
                Button {
                    if door.security == .secure {
                        confirming = door
                    } else {
                        perform { try await home.setSecure(door, true) }
                    }
                } label: {
                    DoorTile(door: door, since: home.insecureSince[door.id], now: now)
                }
                .buttonStyle(TileButtonStyle())
            }
        }
    }

    private var climate: some View {
        HStack(spacing: 14) {
            ForEach(home.climate.prefix(3)) { device in
                ClimateTile(device: device, config: home.config) { delta in
                    perform { try await home.adjustTarget(device, by: delta) }
                }
            }
        }
    }

    private var lights: some View {
        let on = home.lights.filter { $0.isOn == true }
        return VStack(alignment: .leading, spacing: 10) {
            Text(on.isEmpty ? "All lights off" : "\(on.count) of \(home.lights.count) lights on")
                .font(Theme.font(19, .bold))
                .foregroundStyle(Theme.secondary)
            if !on.isEmpty {
                FlowRow(on) { light in
                    Button { perform { try await home.toggle(light) } } label: {
                        Label(light.name, systemImage: "lightbulb.fill")
                            .font(Theme.font(19, .semibold))
                            .foregroundStyle(Theme.today)
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }

    private var scenes: some View {
        FlowRow(home.scenes) { scene in
            Button { perform { try await home.run(scene) } } label: {
                Label(scene.name, systemImage: "sparkles.rectangle.stack")
                    .font(Theme.font(19, .semibold))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(ChipButtonStyle())
        }
    }
}

// MARK: - Tiles

private struct DoorTile: View {
    let door: HomeDevice
    let since: Date?
    let now: Date

    private var isGarage: Bool { door.kind == .garage }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(door.name)
                    .font(Theme.font(20, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(state)
                    .font(Theme.font(17, .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(door.security == .secure ? Theme.panelRaised : color.opacity(0.18)))
    }

    private var symbol: String {
        switch door.security {
        case .secure: isGarage ? "door.garage.closed" : "lock.fill"
        case .open, .moving: isGarage ? "door.garage.open" : "lock.open.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch door.security {
        case .secure: door.isReachable ? Theme.noSchool : Theme.secondary
        case .moving: Theme.deadline
        default: Theme.test
        }
    }

    private var state: String {
        if !door.isReachable { return "Not responding" }
        switch door.security {
        case .secure: return isGarage ? "Closed" : "Locked"
        case .open:
            let minutes = since.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
            let word = isGarage ? "Open" : "Unlocked"
            return minutes > 0 ? "\(word) · \(minutes) min" : word
        case .moving: return "Moving…"
        case .jammed: return "Jammed"
        default: return "Unknown"
        }
    }
}

private struct ClimateTile: View {
    let device: HomeDevice
    let config: HomeConfig
    let adjust: (Double) -> Void

    /// One degree in the configured units, expressed in °C.
    private var step: Double { config.isCelsius ? 0.5 : 5.0 / 9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(device.name)
                .font(Theme.font(17, .bold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Text(device.temperature.map { degrees($0, config) } ?? "—")
                .font(Theme.font(38, .bold))
                .foregroundStyle(Theme.text)
            if let target = device.target {
                Text("\(device.activity ?? "Set") to \(degrees(target, config))")
                    .font(Theme.font(16, .semibold))
                    .foregroundStyle(device.activity == "Heating" ? Theme.deadline : device.activity == "Cooling" ? Color(hex: "#6CB6FF") : Theme.secondary)
                HStack(spacing: 10) {
                    Button { adjust(-step) } label: { Image(systemName: "minus").frame(width: 28) }
                    Button { adjust(step) } label: { Image(systemName: "plus").frame(width: 28) }
                }
                .buttonStyle(ChipButtonStyle())
                .font(Theme.font(18, .bold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
    }
}

/// Wraps items onto as many lines as needed.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(items) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Focus styles

/// Lifts and outlines the focused tile, like the rest of tvOS, without the default white platter.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileFocus(configuration: configuration, cornerRadius: 16)
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileFocus(configuration: configuration, cornerRadius: 30, chip: true)
    }
}

private struct TileFocus: View {
    @Environment(\.isFocused) private var isFocused
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    var chip = false

    var body: some View {
        configuration.label
            .padding(.horizontal, chip ? 18 : 0)
            .padding(.vertical, chip ? 10 : 0)
            .background {
                if chip { RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.panelRaised) }
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(isFocused ? Theme.text : .clear, lineWidth: 3))
            .scaleEffect(configuration.isPressed ? 0.97 : isFocused ? 1.05 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
