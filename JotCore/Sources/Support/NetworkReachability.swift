import Foundation
import Network

/// One-shot connectivity snapshot — for flows that must distinguish "your key is
/// wrong" from "you're offline" (onboarding key validation).
public enum NetworkReachability {
    public static func probablyOnline(timeout: TimeInterval = 1.0) -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var satisfied = false
        monitor.pathUpdateHandler = { path in
            satisfied = path.status == .satisfied
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.ammaar.jot.reachability"))
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return satisfied
    }
}
