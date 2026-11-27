import Foundation
import AppKit

/// The voice's log: `~/Library/Logs/Xool/voice.log`. Everything the sidecar and the bridge do lands here
/// (start, speaker and microphone in use, what was heard, said, errors), so "I heard nothing" can be traced.
/// Test runs write to `XOOL_LOG_DIR` instead (or nowhere), never into the real log.
enum VoiceLog {
    private static let queue = DispatchQueue(label: "xool.voice.log")
    private static let maxBytes = 1_500_000

    static var directory: URL {
        if let set = getenv("XOOL_LOG_DIR") { return URL(fileURLWithPath: String(cString: set), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Xool", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("voice.log") }

    private static var enabled: Bool {
        getenv("XOOL_LOG_DIR") != nil || !(Store.testing || getenv("XOOL_PROFILE") != nil)
    }

    static func write(_ line: String) {
        let text = "\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon))) \(line)\n"
        if let path = getenv("XOOL_VOICE_LOG").map({ String(cString: $0) }) { append(text, to: URL(fileURLWithPath: path)) }
        guard enabled else { return }
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int, size > maxBytes {
                let old = directory.appendingPathComponent("voice.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            append(text, to: file)
        }
    }

    private static func append(_ text: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// "Show voice log": the file in Finder (made first, so there is always something to show).
    @MainActor static func reveal() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { try? "Voice log\n".write(to: file, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
