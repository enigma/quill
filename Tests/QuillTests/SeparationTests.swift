import Foundation

@main
struct SeparationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let config = root.appendingPathComponent("config.json")
        precondition(Config.path.standardizedFileURL.path == config.standardizedFileURL.path)
        precondition(Config.transcriptionEnabled() == false)
        precondition(Config.onStop() == nil)
        precondition(Config.resolveRoot(cliOverride: nil).path == root.appendingPathComponent("recordings").path)
        precondition(Config.resolveRoot(cliOverride: root.appendingPathComponent("cli").path).lastPathComponent == "cli")
        precondition(Config.configPath(environment: [:], home: root).path == root.appendingPathComponent(".config/quill/config.json").path)
        precondition(Config.configPath(environment: ["QUILL_CONFIG_PATH": ""], home: root).path == root.appendingPathComponent(".config/quill/config.json").path)

        var lock: RecordingRootLock? = try RecordingRootLock(root: root.appendingPathComponent("recordings"))
        precondition(lock != nil)
        do {
            _ = try RecordingRootLock(root: root.appendingPathComponent("recordings"))
            fatalError("Two instances acquired the same recording root")
        } catch {}
        let other = try RecordingRootLock(root: root.appendingPathComponent("other-recordings"))
        withExtendedLifetime(other) {}
        lock = nil
        let reopened = try RecordingRootLock(root: root.appendingPathComponent("recordings"))
        withExtendedLifetime(reopened) {}
        print("Separation: config isolation, output precedence, default paths and root locks passed")
    }
}
