import Foundation
import IOKit
import IOUSBHost

public enum ClipError: Error, CustomStringConvertible {
    case notConnected
    case interfaceNotFound
    case timeout
    case usb(String)
    case protocolError(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .notConnected: return "Narrative Clip not found (VID 0xF0F0 / PID 0x1337). Is it plugged in?"
        case .interfaceNotFound: return "Camera USB interface did not appear after configuring the device"
        case .timeout: return "USB request timed out"
        case .usb(let s): return "USB error: \(s)"
        case .protocolError(let s): return "Protocol error: \(s)"
        case .verificationFailed(let s): return "Verification failed: \(s)"
        }
    }
}

/// Raw USB access to the camera: vendor control requests on the default pipe and reads from
/// the bulk IN endpoint. Knows nothing about the camera's commands.
final class USBTransport {
    static let vendorID = 0xF0F0
    static let productID = 0x1337
    static let configurationValue = 1
    static let interfaceNumber = 0
    static let bulkInAddress = 0x81
    static let bulkChunk = 0x10000

    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let readBuffer: NSMutableData

    static func deviceMatching() -> CFMutableDictionary {
        IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber, bcdDevice: nil,
            deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    static var isConnected: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, deviceMatching())
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, Self.deviceMatching())
        guard service != 0 else { throw ClipError.notConnected }
        defer { IOObjectRelease(service) }
        let device = try Self.usb { try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil) }
        let interface = try Self.openInterface(device: device)
        self.device = device
        self.interface = interface
        inPipe = try Self.usb { try interface.copyPipe(withAddress: Self.bulkInAddress) }
        readBuffer = try Self.usb { try interface.ioData(withCapacity: Self.bulkChunk) }
    }

    deinit {
        interface.destroy()
        device.destroy()
    }

    private static func openInterface(device: IOUSBHostDevice) throws -> IOUSBHostInterface {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber, bcdDevice: nil,
            interfaceNumber: interfaceNumber as NSNumber, configurationValue: configurationValue as NSNumber,
            interfaceClass: nil, interfaceSubclass: nil, interfaceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()

        func findInterface() -> io_service_t {
            IOServiceGetMatchingService(kIOMainPortDefault, matching)
        }

        var service = findInterface()
        if service == 0 {
            // Unconfigured device: select the configuration and let the kernel publish the interface.
            try usb { try device.__configure(withValue: configurationValue, matchInterfaces: true) }
            for _ in 0..<50 where service == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                service = findInterface()
            }
        }
        guard service != 0 else { throw ClipError.interfaceNotFound }
        defer { IOObjectRelease(service) }
        return try usb { try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil) }
    }

    /// Port-resets the device (equivalent to unplugging it). The transport is unusable afterwards;
    /// the device re-enumerates and must be opened again.
    func reset() throws {
        try Self.usb { try device.reset() }
    }

    func controlOut(request: UInt8, index: UInt16 = 0, data: Data, timeout: TimeInterval = 5) throws {
        let req = IOUSBDeviceRequest(bmRequestType: 0x40, bRequest: request, wValue: 0, wIndex: index,
                                     wLength: UInt16(data.count))
        let buffer = NSMutableData(data: data)
        var transferred = 0
        try Self.usb {
            try device.__send(req, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        }
    }

    func controlIn(request: UInt8, index: UInt16 = 0, length: Int, timeout: TimeInterval = 5) throws -> Data {
        let req = IOUSBDeviceRequest(bmRequestType: 0xC0, bRequest: request, wValue: 0, wIndex: index,
                                     wLength: UInt16(length))
        let buffer = NSMutableData(length: length)!
        var transferred = 0
        try Self.usb {
            try device.__send(req, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    /// One bulk IN transfer of up to 64 KiB. Always requesting a whole multiple of the packet size
    /// means a terminating zero-length packet is consumed by the transfer it belongs to.
    func bulkRead(timeout: TimeInterval) throws -> Data {
        var transferred = 0
        try Self.usb {
            try inPipe.__sendIORequest(with: readBuffer, bytesTransferred: &transferred, completionTimeout: timeout)
        }
        return Data(bytes: readBuffer.bytes, count: transferred)
    }

    /// Discards anything left in the bulk pipe so the next response isn't read out of step.
    /// (The official app does the same in -[CameraV2 clearPendingData].)
    func drain() {
        while true {
            do { _ = try bulkRead(timeout: 0.1) } catch { return }
        }
    }

    private static func usb<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NSError {
            if IOReturn(truncatingIfNeeded: error.code) == kIOReturnTimeout {
                throw ClipError.timeout
            }
            throw ClipError.usb("\(error.localizedDescription) (0x\(String(UInt32(truncatingIfNeeded: error.code), radix: 16)))")
        }
    }
}
