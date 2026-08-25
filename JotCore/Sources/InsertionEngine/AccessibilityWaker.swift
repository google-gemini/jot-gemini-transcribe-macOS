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

import ApplicationServices
import Foundation

/// Chromium/Electron apps build their accessibility tree lazily; setting
/// `AXManualAccessibility` asks for it. That set is a SYNCHRONOUS cross-process
/// call serialized on the TARGET app's main thread, and the renderer then builds
/// its tree asynchronously — both facts say the same thing: wake at session
/// START, while the user is still speaking, never after the transcript exists
/// and the user is waiting to see their words.
public enum AccessibilityWaker {
    private static let lock = NSLock()
    private static var woken: Set<pid_t> = []

    /// Fire-and-forget; returns in microseconds. Safe from the main actor.
    public static func wakeIfNeeded(bundleID: String?, pid: pid_t?) {
        guard let bundleID, let pid,
              AppQuirks.needsManualAccessibility.contains(bundleID) else { return }
        lock.lock()
        let isFirst = woken.insert(pid).inserted
        lock.unlock()
        guard isFirst else { return } // AX mode is sticky for the app's lifetime
        Task.detached(priority: .utility) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.5)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }
}
