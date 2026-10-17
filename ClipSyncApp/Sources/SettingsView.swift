import SwiftUI

struct SettingsView: View {
    @Bindable var controller: SyncController

    var body: some View {
        Form {
            Section {
                LabeledContent("Library") {
                    HStack {
                        Text(controller.destination.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseDestination)
                    }
                }
            } header: {
                Text("Location")
            } footer: {
                Text("Photos go in “Photos”, named by shot time and rotated upright; each photo’s .json and .snap files go in “Metadata”. Deleting a photo in Narrative Clip Sync moves those to the Trash too.")
            }

            Section("Sync") {
                Toggle("Sync automatically when the camera is connected", isOn: $controller.autoSync)
                Picker("Clear Camera", selection: $controller.deletePolicy) {
                    ForEach(DeletePolicy.allCases) { Text($0.title).tag($0) }
                }
                Text("Only photos that are on your Mac and match byte for byte are deleted. The camera holds about 8 GB, roughly a week of daily wear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at Login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.launchAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = controller.destination
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            controller.destination = url
        }
    }
}
