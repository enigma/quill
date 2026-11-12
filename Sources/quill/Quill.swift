import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)
        let rootLock = try RecordingRootLock(root: root)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        withExtendedLifetime(rootLock) { app.run() }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    @Flag(name: .long, help: "Print identity and paths without checking permissions or creating folders.")
    var pathsOnly = false

    func run() throws {
        print("\(AppIdentity.displayName) · \(AppIdentity.identifier)")
        print("config: \(Config.path.path)")
        print("recordings: \(Config.resolveRoot(cliOverride: nil).path)")
        if pathsOnly { return }
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var diskSpaceTimer: Timer?
    private var isStarting = false
    private var deadline: Date?
    private var nextTitle = ""

    init(root: URL) {
        self.root = root
        menuBar.updateRecordingsRoot(root)
        menuBar.onExtend = { [weak self] in self?.extend(by: $0) }
        menuBar.onTitle = { [weak self] in self?.editTitle() }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onMenuOpen = { [weak self] in self?.refreshDiskSpace(); self?.tick() }
        menuBar.update(recording: false, elapsed: nil)
        refreshDiskSpace()
        let diskTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDiskSpace() }
        }
        RunLoop.main.add(diskTimer, forMode: .common)
        RunLoop.main.add(diskTimer, forMode: .eventTracking)
        diskSpaceTimer = diskTimer

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        diskSpaceTimer?.invalidate()
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        guard !isStarting else { return }
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        refreshDiskSpace()
        isStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isStarting = false }
            do {
                let newSession = try RecordingSession(root: root)
                try newSession.setTitle(nextTitle)
                try await newSession.start()
                session = newSession
                deadline = Date().addingTimeInterval(30 * 60)
                nextTitle = ""
                FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
                notifyUser(title: "quill — recording failed", body: "\(error)")
                return
            }

            menuBar.updateCapture([])
            menuBar.update(recording: true, elapsed: "0:00")
            tick()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // Keep the cutoff active while a menu or title dialog is open.
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .modalPanel)
            ticker = timer
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        deadline = nil
        menuBar.updateTitle(nextTitle)
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session, let deadline else { return }
        menuBar.updateCapture(session.captureActivity())
        let now = Date()
        guard now < deadline else {
            stopSession()
            notifyUser(title: "quill — recording stopped", body: "The recording time limit was reached.")
            return
        }
        menuBar.update(
            recording: true,
            elapsed: Self.format(now.timeIntervalSince(session.startedAt)),
            remaining: Self.format(ceil(deadline.timeIntervalSince(now)))
        )
    }

    private func extend(by interval: TimeInterval) {
        // An overdue recording must stop even if its timer hasn't fired yet.
        tick()
        guard let deadline, session != nil else { return }
        self.deadline = deadline.addingTimeInterval(interval)
        tick()
    }

    private func editTitle() {
        guard !isStarting else { return }
        let target = session
        guard let title = menuBar.promptForTitle(current: target?.title ?? nextTitle) else { return }
        do {
            if let target {
                try target.setTitle(title)
                if session === target { menuBar.updateTitle(title) }
            } else {
                nextTitle = title
                menuBar.updateTitle(title)
            }
        } catch {
            notifyUser(title: "quill — couldn't save title", body: "\(error)")
        }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Check actual free bytes, without counting space macOS might reclaim.
    /// The startup disk matters to system capture even when recordings go
    /// to an external volume. Query fresh filesystem attributes each time.
    private func refreshDiskSpace() {
        let locations: [(String, URL)] = [
            ("startup disk", URL(fileURLWithPath: "/System/Volumes/Data")),
            ("recordings disk", root),
        ]
        var warnings: [String] = []
        for (name, url) in locations {
            do {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
                guard let free = attributes[.systemFreeSize] as? NSNumber else {
                    warnings.append("Can't check \(name) space")
                    continue
                }
                if free.int64Value < 10_000_000_000 {
                    let gb = String(format: "%.1f", Double(free.int64Value) / 1_000_000_000)
                    warnings.append("Low space: \(gb) GB free on \(name) (below 10 GB)")
                    // Usually both paths share a volume; one warning suffices.
                    break
                }
            } catch {
                warnings.append("Can't check \(name) space")
            }
        }
        menuBar.updateDiskSpace(warning: warnings.isEmpty ? nil : warnings.joined(separator: " · "))
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
