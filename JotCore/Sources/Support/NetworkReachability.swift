// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
