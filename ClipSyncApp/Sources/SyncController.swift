import AppKit
import ClipKit
import Foundation
import Observation
import ServiceManagement

enum DeletePolicy: String, CaseIterable, Identifiable {
    case ask, automatic, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return String(localized: "Ask after syncing (recommended)")
        case .automatic: return String(localized: "Clear automatically after verifying")
        case .never: return String(localized: "Never")
        }
    }
}

/// App state: watches for the camera, runs SyncEngine off the main thread and publishes progress.
@MainActor
@Observable
final class SyncController {
    enum Phase: Equatable {
        case disconnected
        case idle
        case syncing
        case clearing
        case failed(String)
    }

    private(set) var phase: Phase = .disconnected
    private(set) var isConnected = false
    private(set) var progress: Double?
    private(set) var progressText = ""
    private(set) var lastSyncDate: Date?
    private(set) var lastNewPhotos = 0
    private(set) var photosReadyToDelete = 0
    private(set) var eventsReadyToDelete = 0
    /// Bumped whenever a sync may have changed the library, so open browser windows reload.
    private(set) var libraryVersion = 0

    var destination: URL {
        didSet { UserDefaults.standard.set(destination.path, forKey: "destination") }
    }
    var deletePolicy: DeletePolicy {
        didSet { UserDefaults.standard.set(deletePolicy.rawValue, forKey: "deletePolicy") }
    }
    var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                phase = .failed(String(localized: "Couldn't change the Open at Login setting: \(error.localizedDescription)"))
            }
        }
    }

    var isBusy: Bool { phase == .syncing || phase == .clearing }

    var menuBarSymbol: String {
        if isBusy { return "arrow.triangle.2.circlepath.camera" }
        if case .failed = phase { return "exclamationmark.triangle" }
        return isConnected ? "camera.fill" : "camera"
    }

    private let monitor = DeviceMonitor()
    private let notifier = Notifier()

    init() {
        let defaults = UserDefaults.standard
        destination = defaults.string(forKey: "destination").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SyncEngine.defaultDestination
        deletePolicy = defaults.string(forKey: "deletePolicy").flatMap(DeletePolicy.init) ?? .ask
        autoSync = defaults.object(forKey: "autoSync") as? Bool ?? true

        notifier.onClearCamera = { [weak self] in self?.clearCamera() }
        notifier.requestAuthorization()

        monitor.onConnect = { [weak self] in self?.cameraConnected() }
        monitor.onDisconnect = { [weak self] in self?.cameraDisconnected() }
        monitor.start()
    }

    func sync() {
        run(deleting: deletePolicy == .automatic)
    }

    /// Re-verifies every event against the Mac's copy, then deletes it from the camera.
    func clearCamera() {
        run(deleting: true)
    }

    func openPhotos() {
        let photos = PhotoLibrary(root: destination).photosFolder
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        NSWorkspace.shared.open(photos)
    }

    // MARK: Device events

    private func cameraConnected() {
        isConnected = true
        if !isBusy { phase = .idle }
        // Our own USB reset (used to recover a wedged camera) also re-announces the device;
        // `run` ignores that while a sync is in progress.
        if autoSync {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sync() }
        }
    }

    private func cameraDisconnected() {
        isConnected = ClipDevice.isConnected
        if !isConnected && !isBusy { phase = .disconnected }
    }

    // MARK: Running

    private func run(deleting: Bool) {
        guard isConnected, !isBusy else { return }
        phase = deleting ? .clearing : .syncing
        progress = nil
        progressText = String(localized: "Connecting…")
        let options = SyncEngine.Options(destination: destination, deleteFromCamera: deleting)
        let report: @Sendable (SyncEngine.Progress) -> Void = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        let complete: @Sendable (Result<SyncEngine.Summary, Error>) -> Void = { [weak self] result in
            Task { @MainActor in self?.finish(result, deleting: deleting) }
        }

        // ClipDevice does blocking USB I/O, so the whole run happens off the main thread.
        Task.detached(priority: .userInitiated) {
            complete(Result { try SyncEngine(device: try ClipDevice()).run(options, progress: report) })
        }
    }

    private func apply(_ update: SyncEngine.Progress) {
        switch update {
        case .clockSet:
            progressText = String(localized: "Camera clock set, scanning…")
        case .scanned(_, let photos):
            progress = photos == 0 ? nil : 0
            progressText = photos == 0 ? String(localized: "No new photos") : String(localized: "Preparing to transfer \(photos) photos")
        case .transferred(_, let done, let total):
            progress = Double(done) / Double(max(total, 1))
            progressText = phase == .clearing
                ? String(localized: "Verifying photo \(done) of \(total)")
                : String(localized: "Transferring photo \(done) of \(total)")
        case .mismatch:
            progressText = String(localized: "Some photos didn't match and were kept on the camera")
        case .deleted:
            progressText = String(localized: "Clearing files from the camera…")
        }
    }

    private func finish(_ result: Result<SyncEngine.Summary, Error>, deleting: Bool) {
        progress = nil
        progressText = ""
        switch result {
        case .success(let summary):
            libraryVersion += 1
            phase = isConnected ? .idle : .disconnected
            lastSyncDate = Date()
            lastNewPhotos = summary.newPhotos.count
            photosReadyToDelete = summary.photosReadyToDelete
            eventsReadyToDelete = summary.eventsReadyToDelete
            if summary.mismatches > 0 {
                phase = .failed(String(localized: "\(summary.mismatches) files didn't match and were kept on the camera"))
            }
            if deleting {
                notifier.postCleared(deletedFiles: summary.deletedFiles, newPhotos: summary.newPhotos.count)
            } else if summary.newPhotos.count > 0 || (deletePolicy == .ask && summary.photosReadyToDelete > 0) {
                notifier.postSynced(newPhotos: summary.newPhotos.count,
                                    photosReadyToDelete: deletePolicy == .ask ? summary.photosReadyToDelete : 0)
            }
        case .failure(let error):
            phase = .failed("\(error)")
        }
    }
}
