import Foundation

/// Narrative Clip 1 protocol, reverse-engineered from Narrative Uploader 2.5.3
/// (CameraV2 / ClipOneStrategy):
///
/// * Commands are vendor control requests (bmRequestType 0x40 OUT / 0xC0 IN, wValue 0).
///   Path arguments are NUL-terminated strings in the data stage.
/// * File responses arrive on bulk IN 0x81. Directory entries and file headers are 132-byte
///   records: u32 size @0, u32 d_type @4 (low byte only: 4 = dir, 8 = file), char name[124] @8.
/// * Set-property and delete are answered with "ACK" on the bulk pipe.
/// * Firmware update (0x10/0x11) is deliberately not implemented.
public final class ClipDevice {
    public static let storageRoot = "/mnt/storage"

    public struct Info: Sendable {
        public let identifier: String
        public let firmwareVersion: String
        public let cameraTime: Date
        public var clockOffset: TimeInterval { Date().timeIntervalSince(cameraTime) }
    }

    public struct Entry: Sendable {
        public let name: String
        public let size: Int
        public let isDirectory: Bool
    }

    private enum Request: UInt8 {
        case readFile = 0x02
        case deleteFile = 0x03
        case getProperty = 0x04
        case setProperty = 0x05
        case listDirectory = 0x09
    }

    private enum Property: UInt16 {
        case deviceIdentifier = 1
        case firmwareVersion = 2
        case time = 4
    }

    private static let entrySize = 0x84
    private static let endMarker: [UInt8] = [0x00, 0xFF, 0xFF, 0x55, 0xAA, 0xFF, 0xFF, 0x00]
    private static let dtDir: UInt8 = 4

    private var transport: USBTransport
    private var pipeMayHoldStaleData = true

    public static var isConnected: Bool { USBTransport.isConnected }

    /// Opens the camera. A transfer left half-read by an earlier session can wedge the firmware so
    /// that even control requests time out; a USB port reset recovers it without touching storage.
    public init() throws {
        transport = try USBTransport()
        do {
            _ = try getProperty(.deviceIdentifier)
        } catch ClipError.timeout {
            try transport.reset()
            transport = try Self.reopenAfterReset()
            _ = try getProperty(.deviceIdentifier)
        }
    }

    private static func reopenAfterReset() throws -> USBTransport {
        var lastError: Error = ClipError.notConnected
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            do { return try USBTransport() } catch { lastError = error }
        }
        throw lastError
    }

    // MARK: Properties

    private func getProperty(_ property: Property, length: Int = 0x80) throws -> Data {
        try transport.controlIn(request: Request.getProperty.rawValue, index: property.rawValue, length: length)
    }

    public func info() throws -> Info {
        let time = try getProperty(.time)
        guard time.count >= 4 else { throw ClipError.protocolError("short time property (\(time.count) bytes)") }
        return Info(
            identifier: Self.cString(try getProperty(.deviceIdentifier)),
            firmwareVersion: Self.cString(try getProperty(.firmwareVersion)),
            cameraTime: Date(timeIntervalSince1970: TimeInterval(time.readUInt32LE(at: 0)))
        )
    }

    /// Sets the camera clock (the official app does this on every connect).
    public func setTime(_ date: Date = Date()) throws {
        try bulkCommand { try setTimeCommand(date) }
    }

    private func setTimeCommand(_ date: Date) throws {
        var seconds = UInt32(date.timeIntervalSince1970).littleEndian
        try transport.controlOut(request: Request.setProperty.rawValue, index: Property.time.rawValue,
                                 data: Data(bytes: &seconds, count: 4))
        try waitForACK("set time")
    }

    // MARK: Files

    public func listDirectory(_ path: String) throws -> [Entry] {
        try bulkCommand { try listDirectoryCommand(path) }
    }

    private func listDirectoryCommand(_ path: String) throws -> [Entry] {
        try sendPathCommand(.listDirectory, path)
        var buffer = Data()
        while true {
            buffer.append(try transport.bulkRead(timeout: 60))
            let count = buffer.count / Self.entrySize
            if count > 0 && Array(buffer[Self.recordRange(count - 1, field: 8..<16)]) == Self.endMarker { break }
        }
        let count = buffer.count / Self.entrySize - 1
        return (0..<count).map { i in
            let base = i * Self.entrySize
            return Entry(
                name: Self.cString(buffer[(base + 8)..<(base + Self.entrySize)]),
                size: Int(buffer.readUInt32LE(at: base)),
                isDirectory: buffer[buffer.startIndex + base + 4] == Self.dtDir
            )
        }
    }

    public func readFile(_ path: String) throws -> Data {
        try bulkCommand { try readFileCommand(path) }
    }

    private func readFileCommand(_ path: String) throws -> Data {
        try sendPathCommand(.readFile, path)
        var first = Data()
        while first.count < Self.entrySize {
            first.append(try transport.bulkRead(timeout: 10))
        }
        let size = Int(first.readUInt32LE(at: 0))
        let name = Self.cString(first[first.startIndex + 8..<first.startIndex + Self.entrySize])
        guard size > 0, name == path else {
            throw ClipError.protocolError("invalid file: path=\(path), f_name=\(name), size=\(size)")
        }
        var data = Data(first.dropFirst(Self.entrySize))
        data.reserveCapacity(size)
        while data.count < size {
            data.append(try transport.bulkRead(timeout: 60))
        }
        guard data.count == size else {
            throw ClipError.protocolError("size mismatch for \(path): expected \(size), got \(data.count)")
        }
        return data
    }

    public func deleteFile(_ path: String) throws {
        try bulkCommand { try deleteFileCommand(path) }
    }

    private func deleteFileCommand(_ path: String) throws {
        try sendPathCommand(.deleteFile, path)
        try waitForACK("delete \(path)")
    }

    // MARK: Helpers

    /// Runs a command that answers on the bulk pipe. The pipe is drained first only when it may
    /// hold stale data: right after opening, or after a command failed part-way. Draining costs a
    /// 100 ms timeout, which adds up when scanning ~100 directories.
    private func bulkCommand<T>(_ body: () throws -> T) throws -> T {
        if pipeMayHoldStaleData {
            transport.drain()
            pipeMayHoldStaleData = false
        }
        do {
            return try body()
        } catch {
            pipeMayHoldStaleData = true
            throw error
        }
    }

    private func sendPathCommand(_ request: Request, _ path: String) throws {
        var data = Data(path.utf8)
        data.append(0)
        try transport.controlOut(request: request.rawValue, data: data)
    }

    private func waitForACK(_ what: String) throws {
        let reply = try transport.bulkRead(timeout: 20)
        guard Self.cString(reply) == "ACK" else {
            throw ClipError.protocolError("camera did not ACK \(what): \(Array(reply.prefix(8)))")
        }
    }

    private static func recordRange(_ index: Int, field: Range<Int>) -> Range<Int> {
        (index * entrySize + field.lowerBound)..<(index * entrySize + field.upperBound)
    }

    private static func cString(_ data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
