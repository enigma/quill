import Darwin
import Foundation

/// Hold the recordings directory exclusively before scanning pending sessions.
/// Kernel locks release on exit/crash; keep the file so another process cannot
/// bypass a held lock by creating a replacement inode.
final class RecordingRootLock {
    private var descriptor: Int32 = -1

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".quill.lock").path
        let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Cannot lock recordings folder: \(root.path)",
            ])
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(opened)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Recordings folder is already in use or cannot be locked: \(root.path). Quit the other Quill or choose a separate test folder.",
            ])
        }
        descriptor = opened
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
