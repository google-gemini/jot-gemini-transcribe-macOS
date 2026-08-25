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

import Carbon.HIToolbox
import Darwin
import Foundation
import IOKit

/// TN2150: when any app enables secure input (password fields, Terminal's Secure
/// Keyboard Entry), event taps stop seeing keystrokes and dictating into the field
/// would be a credential leak. We refuse politely and never bypass.
public enum SecureInput {
    public static var isActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// The process currently holding secure input, if the window server will say.
    ///
    /// Worth the IOKit trip because "secure input is on" is a macOS concept almost
    /// nobody knows, and the flag is system-wide — the app that turned it on is
    /// usually NOT the one the user is looking at. Naming it turns a dead end into
    /// something actionable, which matters most during onboarding where a stuck
    /// flag otherwise reads as "this app is broken".
    public static func holder() -> (pid: pid_t, name: String)? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let property = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for session in property {
            guard let raw = session["kCGSSessionSecureInputPID"] as? Int32, raw != 0 else { continue }
            return (raw, name(of: raw) ?? "another app")
        }
        return nil
    }

    /// Plain-language advice for the holder we found. The three cases below cover
    /// essentially every real occurrence: a stuck lock screen, a terminal with
    /// Secure Keyboard Entry left on, and a focused password field.
    public static func advice(forHolder name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("loginwindow") {
            return "Lock your screen and unlock it to clear this."
        }
        if lowered.contains("terminal") || lowered.contains("iterm") {
            return "Turn off Secure Keyboard Entry in \(name)'s menu."
        }
        return "Click out of any password field in \(name)."
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
