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

import AppKit
import XCTest
@testable import JotCore
/// Keeping a transcript around is a marker decision, not just a write: the
/// transient type is what tells a clipboard manager to skip it, so "keep it so I
/// can reuse it" has to drop that marker or the manager the user relies on will
/// throw the transcript away for them.
@MainActor
final class ClipboardRetentionTests: XCTestCase {
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The suite runs against the real general pasteboard — put back whatever
    /// the developer had copied.
    private func withRestoredClipboard(_ body: () -> Void) {
        let previous = NSPasteboard.general.string(forType: .string)
        body()
        NSPasteboard.general.clearContents()
        if let previous {
            NSPasteboard.general.setString(previous, forType: .string)
        }
    }

    func testCopyOnlyMarksTranscriptsTransientByDefault() {
        withRestoredClipboard {
            PasteInserter().copyOnly("a transcript")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a transcript")
            XCTAssertNotNil(
                NSPasteboard.general.pasteboardItems?.first?.string(forType: transient),
                "audit L22: managers must skip transcripts unless asked otherwise"
            )
        }
    }

    func testArchivableCopyDropsTheTransientMarker() {
        withRestoredClipboard {
            PasteInserter().copyOnly("a transcript", archivable: true)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a transcript")
            XCTAssertNil(
                NSPasteboard.general.pasteboardItems?.first?.string(forType: transient),
                "the user asked to keep this one — their clipboard manager should see it"
            )
        }
    }
}

/// The clipboard half: can text land where the user is pointing?
final class EditableTargetTests: XCTestCase {
    /// Settable outranks role. Whatever an element calls itself, a settable
    /// selected-text attribute IS somewhere text can go.
    func testSettableIsEditableWhateverTheRole() {
        XCTAssertEqual(
            AXInserter.classifyTarget(role: "AXButton", settable: true, hasStringValue: false),
            .editable
        )
    }

    func testInertControlHasNoTextDestination() {
        for role in ["AXButton", "AXCheckBox", "AXMenuItem", "AXImage", "AXStaticText"] {
            XCTAssertEqual(
                AXInserter.classifyTarget(role: role, settable: false, hasStringValue: false),
                .noEditableTarget,
                "\(role) cannot receive a paste"
            )
        }
    }

    /// The conservative guarantee, and the reason the inert list is short.
    /// Containers and web areas are exactly what a contenteditable or a lying
    /// Electron wrapper reports while still accepting ⌘V — they must keep
    /// reaching the paste tier, because being wrong here costs a real insertion.
    func testContainerAndWebRolesStayUnknown() {
        for role in ["AXGroup", "AXScrollArea", "AXWebArea", "AXUnknown", "AXTextArea", "AXWindow"] {
            XCTAssertEqual(
                AXInserter.classifyTarget(role: role, settable: false, hasStringValue: false),
                .unknown,
                "\(role) is not proof of anything — paste is still the right guess"
            )
        }
    }

    /// A readable value means some kind of editor, even if we cannot drive it.
    func testReadableValueStaysUnknown() {
        XCTAssertEqual(
            AXInserter.classifyTarget(role: "AXStaticText", settable: false, hasStringValue: true),
            .unknown
        )
    }

    func testMissingRoleStaysUnknown() {
        XCTAssertEqual(
            AXInserter.classifyTarget(role: nil, settable: false, hasStringValue: false),
            .unknown
        )
    }
}
