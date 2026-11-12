import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
@MainActor
final class RecordingSession {
    let dir: URL
    let startedAt = Date()
    private(set) var title = ""

    private var lastHealth: [String: String] = [:]
    private var captureLog: FileHandle?
    private(set) var captureWarnings: [String] = []

    /// Read counters only; never inspect growing audio files during capture.
    func captureActivity() -> [(String, CaptureActivity.Snapshot)] {
        let tracks = [("Microphone", mic.activity.snapshot()), ("System audio", system.activity.snapshot())]
        for (name, snapshot) in tracks {
            let health = snapshot.warning ? (snapshot.error ?? snapshot.state) : (snapshot.frames == 0 ? "Waiting" : "Saving")
            if lastHealth[name] != health {
                lastHealth[name] = health
                log("\(name): \(health); written_frames=\(snapshot.frames)")
                if snapshot.warning {
                    let warning = "\(name): \(health)"
                    if !captureWarnings.contains(warning) { captureWarnings.append(warning) }
                }
            }
        }
        return tracks
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        do { try captureLog?.write(contentsOf: Data(line.utf8)) }
        catch { FileHandle.standardError.write(Data("capture log write failed: \(error)\n".utf8)) }
    }

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("capture.log")
        try Data().write(to: logURL)
        captureLog = try FileHandle(forWritingTo: logURL)
        log("Session created")
    }

    /// Persist immediately so the title survives even an unclean shutdown.
    /// Keep the directory stable while capture and transcription use it.
    func setTitle(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data((value.isEmpty ? "" : value + "\n").utf8)
            .write(to: dir.appendingPathComponent("title.txt"), options: .atomic)
        title = value
    }

    /// Start the mic first so its route is settled before system capture. If
    /// ScreenCaptureKit fails, tear the mic down so we never run half a
    /// session silently.
    func start() async throws {
        log("Starting microphone and system audio")
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
            try await system.start(writingTo: dir.appendingPathComponent("system.caf"))
        } catch {
            log("Start failed: \(error)")
            mic.stop()
            throw error
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        _ = captureActivity()
        mic.stop()
        system.stop()
        log("Stopped; mic_frames=\(mic.activity.snapshot().frames); system_frames=\(system.activity.snapshot().frames)")

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "capture_warnings": captureWarnings,
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            do { try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic) }
            catch { log("Metadata write failed: \(error)") }
        }
        try? captureLog?.close()
        captureLog = nil
    }
}
