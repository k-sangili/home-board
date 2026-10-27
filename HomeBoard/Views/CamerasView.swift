import HomeKit
import SwiftUI

/// Every HomeKit camera as a snapshot that refreshes every 10 seconds; select one for live video.
struct CamerasView: View {
    @Environment(HomeStore.self) private var home
    @State private var live: HomeCamera?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelTitle(text: "Cameras", symbol: "video.fill")
            if home.cameras.isEmpty {
                Text(home.status == .ready ? "No HomeKit cameras in this home." : "Waiting for HomeKit…")
                    .font(Theme.font(24, .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: home.cameras.count > 4 ? 3 : 2), spacing: 28) {
                    ForEach(home.cameras) { camera in
                        Button { live = camera } label: {
                            CameraTile(camera: camera, profile: home.cameraProfile(for: camera.id), live: false)
                        }
                        .buttonStyle(TileButtonStyle())
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .fullScreenCover(item: $live) { camera in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                CameraFeed(profile: home.cameraProfile(for: camera.id), live: true)
                    .ignoresSafeArea()
                Text(camera.name)
                    .font(Theme.font(28, .bold))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(40)
            }
        }
    }
}

private struct CameraTile: View {
    let camera: HomeCamera
    let profile: HMCameraProfile?
    let live: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CameraFeed(profile: profile, live: live)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Theme.panelRaised)
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                Text(camera.name)
                if !camera.room.isEmpty {
                    Text(camera.room).foregroundStyle(Theme.secondary)
                }
            }
            .font(Theme.font(20, .bold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// HomeKit's camera view, showing either refreshing snapshots or a live stream.
private struct CameraFeed: UIViewRepresentable {
    let profile: HMCameraProfile?
    let live: Bool

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.backgroundColor = UIColor(Theme.panelRaised)
        context.coordinator.attach(view: view, profile: profile, live: live)
        return view
    }

    func updateUIView(_ view: HMCameraView, context: Context) {}

    static func dismantleUIView(_ view: HMCameraView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, HMCameraSnapshotControlDelegate, HMCameraStreamControlDelegate {
        private weak var view: HMCameraView?
        private var profile: HMCameraProfile?
        private var timer: Timer?

        func attach(view: HMCameraView, profile: HMCameraProfile?, live: Bool) {
            self.view = view
            self.profile = profile
            guard let profile else { return }
            if live, let stream = profile.streamControl {
                stream.delegate = self
                stream.startStream()
            } else if let snapshots = profile.snapshotControl {
                snapshots.delegate = self
                if let latest = snapshots.mostRecentSnapshot { view.cameraSource = latest }
                snapshots.takeSnapshot()
                timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in snapshots.takeSnapshot() }
            }
        }

        func detach() {
            timer?.invalidate()
            profile?.streamControl?.stopStream()
        }

        func snapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
            if let snapshot { view?.cameraSource = snapshot }
        }

        func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
            view?.cameraSource = cameraStreamControl.cameraStream
        }

        func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: Error?) {}
    }
}
