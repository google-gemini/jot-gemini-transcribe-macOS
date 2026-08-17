import os

/// Central loggers, one per subsystem area. Subsystem matches the app bundle id.
public enum Log {
    public static let subsystem = "com.google.transcribe"

    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
