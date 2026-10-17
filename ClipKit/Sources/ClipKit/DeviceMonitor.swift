import Foundation
import IOKit

/// Reports when a Narrative Clip is plugged in or removed, via IOKit matching notifications.
/// Callbacks are delivered on the main queue.
public final class DeviceMonitor {
    public var onConnect: () -> Void = {}
    public var onDisconnect: () -> Void = {}

    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []

    public init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }

    /// Starts watching. If a camera is already connected, `onConnect` fires right away.
    public func start() {
        guard iterators.isEmpty else { return }
        add(kIOFirstMatchNotification) { $0.onConnect() }
        add(kIOTerminatedNotification) { $0.onDisconnect() }
    }

    private func add(_ type: String, handler: @escaping (DeviceMonitor) -> Void) {
        let box = Unmanaged.passRetained(Callback(monitor: self, handler: handler))
        var iterator: io_iterator_t = 0
        IOServiceAddMatchingNotification(port, type, USBTransport.deviceMatching(), { refcon, iterator in
            let callback = Unmanaged<Callback>.fromOpaque(refcon!).takeUnretainedValue()
            if DeviceMonitor.drain(iterator), let monitor = callback.monitor { callback.handler(monitor) }
        }, box.toOpaque(), &iterator)
        iterators.append(iterator)
        // Arms the notification and reports devices that are already present.
        if Self.drain(iterator) && type == kIOFirstMatchNotification { handler(self) }
    }

    /// Consumes all services from the iterator (required to re-arm it); returns whether any were seen.
    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var seen = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            seen = true
        }
        return seen
    }

    private final class Callback {
        weak var monitor: DeviceMonitor?
        let handler: (DeviceMonitor) -> Void
        init(monitor: DeviceMonitor, handler: @escaping (DeviceMonitor) -> Void) {
            self.monitor = monitor
            self.handler = handler
        }
    }
}
