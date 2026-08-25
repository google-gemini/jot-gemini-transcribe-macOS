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

import os

/// Central loggers, one per subsystem area. Subsystem matches the app bundle id.
public enum Log {
    public static let subsystem = "com.ammaar.jot"

    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
