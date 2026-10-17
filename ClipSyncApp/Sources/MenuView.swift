import SwiftUI

struct MenuView: View {
    let controller: SyncController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if controller.isBusy {
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = controller.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(controller.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if case .failed(let message) = controller.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let date = controller.lastSyncDate {
                Text("Last synced \(date.formatted(.relative(presentation: .named))) · \(controller.lastNewPhotos) new")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { controller.sync() }
                .disabled(!controller.isConnected || controller.isBusy)

            if controller.eventsReadyToDelete > 0 && !controller.isBusy {
                clearButton
            }

            Button("Browse Photos", systemImage: "photo.on.rectangle") {
                NSApp.activate()
                openWindow(id: "browser")
            }
            Button("Open in Finder", systemImage: "folder") { controller.openPhotos() }

            Divider()

            Button("Settings…", systemImage: "gearshape") {
                NSApp.activate()
                openSettings()
            }
            Button("Quit Narrative Clip Sync", systemImage: "power") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 300)
        .onChange(of: controller.isBusy) { confirmingClear = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.isConnected ? "camera.fill" : "camera")
                .font(.title2)
                .foregroundStyle(controller.isConnected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Narrative Clip").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: LocalizedStringKey {
        switch controller.phase {
        case .disconnected: return "Not Connected"
        case .idle: return "Connected"
        case .syncing: return "Syncing…"
        case .clearing: return "Verifying and clearing…"
        case .failed: return controller.isConnected ? "Connected (last action failed)" : "Not Connected"
        }
    }

    /// Two-step confirmation inside the panel; a modal dialog would close the menu bar window.
    @ViewBuilder
    private var clearButton: some View {
        let photos = controller.photosReadyToDelete
        let label: LocalizedStringKey = photos > 0 ? "Clear \(photos) Backed-Up Photos from Camera" : "Clear Backed-Up Logs from Camera"
        if confirmingClear {
            HStack {
                Button("Clear Now", systemImage: "trash", role: .destructive) {
                    confirmingClear = false
                    controller.clearCamera()
                }
                .foregroundStyle(.red)
                Spacer()
                Button("Cancel") { confirmingClear = false }
            }
            Text("Each file is compared byte for byte with the copy on your Mac once more before it's deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(label, systemImage: "trash") { confirmingClear = true }
                .disabled(!controller.isConnected)
        }
    }
}
