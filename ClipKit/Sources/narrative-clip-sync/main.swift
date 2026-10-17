import ClipKit
import Foundation

let usage = """
usage: narrative-clip-sync <command> [options]

  info                         camera identifier, firmware and clock
  ls [PATH]                    list a camera directory (default /mnt/storage)
  get PATH [-o FILE]           copy one file from the camera
  settime                      set the camera clock to the Mac's time
  pull [--dest DIR] [--delete] [--no-set-time]
                               copy photos to the Mac; --delete clears verified events from the camera
  import DIR [--library DIR] [--shift-utc-day YYYY-MM-DD=SECONDS]...
                               move a folder of camera originals (earlier app layout or Narrative
                               Uploader export) into the library, one copy per photo; no camera
                               needed. --shift-utc-day corrects photos taken on that UTC day while
                               the camera clock was wrong
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func format(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate, .withTime, .withSpaceBetweenDateAndTime, .withColonSeparatorInTime]
    return f.string(from: date) + " UTC"
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func options(_ name: String) -> [String] {
    args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
}

if command == "import" {
    guard let source = args.first, !source.hasPrefix("--") else { fail(usage) }
    let library = option("--library").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SyncEngine.defaultDestination
    var shifts: [String: TimeInterval] = [:]
    for spec in options("--shift-utc-day") {
        let parts = spec.split(separator: "=")
        guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { fail("bad --shift-utc-day \(spec)") }
        shifts[String(parts[0])] = seconds
    }
    let utcDay = DateFormatter()
    utcDay.locale = Locale(identifier: "en_US_POSIX")
    utcDay.timeZone = TimeZone(identifier: "UTC")
    utcDay.dateFormat = "yyyy-MM-dd"

    let report = PhotoLibrary(root: library).importOriginals(
        at: URL(fileURLWithPath: source, isDirectory: true),
        correctDate: { date in date.addingTimeInterval(shifts[utcDay.string(from: date)] ?? 0) },
        progress: { print($0) }
    )
    report.failed.forEach { print("FAILED \($0)") }
    print("done: \(report.imported) imported, \(report.alreadyPresent) already present, \(report.otherFilesKept) other file(s) kept, \(report.failed.count) failed")
    exit(report.failed.isEmpty ? 0 : 1)
}

do {
    let clip = try ClipDevice()
    switch command {
    case "info":
        let info = try clip.info()
        print("device_identifier  \(info.identifier)")
        print("firmware_version   \(info.firmwareVersion)")
        print("camera_time        \(format(info.cameraTime))")
        print("time_diff_s        \(Int(info.clockOffset.rounded()))")

    case "ls":
        for e in try clip.listDirectory(args.first ?? ClipDevice.storageRoot) {
            print("\(e.isDirectory ? "d" : "-") \(String(e.size).leftPad(10))  \(e.name)")
        }

    case "get":
        guard let path = args.first else { fail(usage) }
        let out = option("-o") ?? (path as NSString).lastPathComponent
        let data = try clip.readFile(path)
        try data.write(to: URL(fileURLWithPath: out))
        print("\(data.count) bytes -> \(out)")

    case "settime":
        let before = try clip.info()
        try clip.setTime()
        let after = try clip.info()
        print("camera_time \(format(before.cameraTime)) -> \(format(after.cameraTime)) (was off by \(Int(before.clockOffset.rounded())) s)")

    case "pull":
        var options = SyncEngine.Options(deleteFromCamera: args.contains("--delete"), setClock: !args.contains("--no-set-time"))
        if let dest = option("--dest") { options.destination = URL(fileURLWithPath: dest, isDirectory: true) }
        let summary = try SyncEngine(device: clip).run(options) { progress in
            switch progress {
            case .clockSet(let offset): print("clock set (was off by \(Int(offset.rounded())) s)")
            case .scanned(let events, let photos): print("\(events) event(s) on camera, \(photos) photo(s) to transfer")
            case .transferred(let photo, let done, let total): print("[\(done)/\(total)] \(photo)")
            case .mismatch(let photo): print("MISMATCH \(photo) -- keeping it on camera")
            case .deleted(let event, let files):
                if !event.isEmpty && files > 1 { print("deleted  \(event) (\(files) files)") }
            }
        }
        print("done: \(summary.newPhotos.count) new photo(s), \(summary.deletedFiles) deleted from camera, \(summary.eventsReadyToDelete) event(s) ready to delete, \(summary.mismatches) mismatch(es)")

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
