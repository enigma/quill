import Foundation

/// Small, synchronized snapshots shared by audio callbacks and the menu.
/// No filesystem access, UI work, or logging runs inside this lock.
final class CaptureActivity: @unchecked Sendable {
    struct Snapshot: Sendable {
        let state: String
        let level: Float
        let frames: UInt64
        let error: String?
        var warning: Bool { error != nil || state == "No data" || state == "Not saving" }
    }

    private let lock = NSLock()
    private var started = ProcessInfo.processInfo.systemUptime
    private var received: TimeInterval?
    private var written: TimeInterval?
    private var peak: Float = 0
    private var frames: UInt64 = 0
    private var failure: String?

    func begin(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        started = now
        received = nil
        written = nil
        peak = 0
        frames = 0
        failure = nil
    }

    func receive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        received = now
    }

    func saved(frames count: UInt32, peak value: Float,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        written = now
        frames += UInt64(count)
        peak = value.isFinite ? max(0, value) : 0
        // Explicit errors remain visible even if a subsequent write succeeds.
    }

    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        failure = message
    }

    func snapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let state: String
        if failure != nil { state = "Capture error" }
        else if now - (received ?? started) > 5 { state = "No data" }
        else if now - (written ?? started) > 5 { state = "Not saving" }
        else if written == nil { state = "Waiting" }
        else { state = peak < 0.0001 ? "Quiet · saving" : "Receiving · saving" }
        let fresh = written.map { now - $0 < 0.5 } ?? false
        let level: Float = fresh && peak > 0 ? min(1, max(0, (20 * log10(peak) + 60) / 60)) : 0
        return Snapshot(state: state, level: level, frames: frames, error: failure)
    }
}
