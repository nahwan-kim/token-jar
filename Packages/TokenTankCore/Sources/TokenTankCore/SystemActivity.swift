import AppKit
import Foundation
import Network

/// Sleep/wake notifications from `NSWorkspace` and the default route's reachability from
/// `NWPathMonitor`. Neither carries provider data or opens a connection.
public final class SystemActivityMonitor: SystemActivityMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tokentank.system-activity", qos: .utility)

    public init() {}

    public func events() -> AsyncStream<SystemActivityEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SystemActivityEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let monitor = NWPathMonitor()
        let center = NSWorkspace.shared.notificationCenter
        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { _ in
            continuation.yield(.willSleep)
        }
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [queue] _ in
            continuation.yield(.didWake)
            // The path may not change across a short sleep; report what it is now so the
            // coordinator does not wait for the full wake grace when the network is already up.
            queue.async {
                continuation.yield(.networkPathChanged(isSatisfied: monitor.currentPath.status == .satisfied))
            }
        }
        monitor.pathUpdateHandler = { path in
            continuation.yield(.networkPathChanged(isSatisfied: path.status == .satisfied))
        }
        monitor.start(queue: queue)
        let observers = ObserverTokens([sleepObserver, wakeObserver])
        continuation.onTermination = { _ in
            monitor.cancel()
            for observer in observers.tokens { center.removeObserver(observer) }
        }
        return stream
    }
}

private final class ObserverTokens: @unchecked Sendable {
    let tokens: [any NSObjectProtocol]

    init(_ tokens: [any NSObjectProtocol]) {
        self.tokens = tokens
    }
}
