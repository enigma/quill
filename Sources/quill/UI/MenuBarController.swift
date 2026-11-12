import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let titleItem: NSMenuItem
    private var extensionItems: [NSMenuItem] = []

    var onExtend: ((TimeInterval) -> Void)?
    var onTitle: (() -> Void)?
    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        toggleItem = NSMenuItem(
            title: "Start recording (30′ adjustable)",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        titleItem = NSMenuItem(title: "Set recording title…", action: #selector(titleClicked), keyEquivalent: "")

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        menu.addItem(toggleItem)

        for (title, minutes) in [("Extend 10′", 10), ("Extend 30′", 30), ("Extend 1h", 60)] {
            let item = NSMenuItem(title: title, action: #selector(extendClicked(_:)), keyEquivalent: "")
            item.tag = minutes
            item.isHidden = true
            menu.addItem(item)
            extensionItems.append(item)
        }

        menu.addItem(titleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, titleItem, openFolder, quit] + extensionItems {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?, remaining: String? = nil) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00") · \(remaining ?? "30:00") remaining" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording (30′ adjustable)"
        extensionItems.forEach { $0.isHidden = !recording }
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    func updateTitle(_ title: String) {
        titleItem.title = title.isEmpty ? "Set recording title…" : "Edit recording title… (\(title))"
    }

    func promptForTitle(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Recording title"
        alert.informativeText = "Optional. Saved as title.txt in the recording folder."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        field.placeholderString = "e.g. Weekly planning"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func extendClicked(_ sender: NSMenuItem) { onExtend?(TimeInterval(sender.tag * 60)) }
    @objc private func titleClicked() { onTitle?() }
    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
