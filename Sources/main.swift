import AppKit

struct CommandResult {
    let output: String
    let error: String
    let status: Int32
}

final class Kubectl {
    let executable: String?
    init() {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        executable = (paths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
            .map { $0 + "/kubectl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(_ arguments: [String]) -> CommandResult {
        guard let executable else {
            return CommandResult(output: "", error: "kubectl was not found. Install it in /opt/homebrew/bin or /usr/local/bin, then restart KubeBar.", status: 127)
        }
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        // Read both pipes concurrently so large configurations cannot fill a pipe and deadlock.
        let reads = DispatchGroup()
        let lock = NSLock()
        var output = Data(), error = Data()
        do { try process.run() } catch {
            return CommandResult(output: "", error: error.localizedDescription, status: 1)
        }
        reads.enter()
        DispatchQueue.global().async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); output = data; lock.unlock()
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global().async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); error = data; lock.unlock()
            reads.leave()
        }
        process.waitUntilExit()
        reads.wait()
        return CommandResult(output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                             error: String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                             status: process.terminationStatus)
    }
}

private func displayName(for context: String) -> String {
    let saved = UserDefaults.standard.dictionary(forKey: "contextAliases") as? [String: String] ?? [:]
    let alias = saved[context] ?? context
    return alias.isEmpty ? context : alias
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let kubectl = Kubectl()
    private let worker = DispatchQueue(label: "KubeBar.kubectl")
    private var contexts: [String] = []
    private var current = ""
    private var errorMessage: String?
    private var busy = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "helm", accessibilityDescription: "Kubernetes context")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        return result
    }

    private func rebuildMenu() {
        let label = current.isEmpty ? "No context" : displayName(for: current)
        statusItem.button?.title = " " + (label.count > 28 ? String(label.prefix(25)) + "…" : label)
        statusItem.button?.toolTip = errorMessage ?? "Kubernetes context: \(current.isEmpty ? label : current)"
        menu.removeAllItems()
        menu.addItem(item(busy ? "Updating…" : "Kubernetes contexts"))
        menu.addItem(.separator())
        for context in contexts {
            let entry = item(displayName(for: context), action: #selector(switchContext(_:)))
            entry.toolTip = context
            entry.representedObject = context
            entry.state = context == current ? .on : .off
            entry.isEnabled = !busy
            menu.addItem(entry)
        }
        if contexts.isEmpty { menu.addItem(item("No contexts configured")) }
        if errorMessage != nil {
            menu.addItem(.separator())
            menu.addItem(item("View error…", action: #selector(showError)))
        }
        menu.addItem(.separator())
        let refreshItem = item("Refresh", action: #selector(refresh))
        refreshItem.isEnabled = !busy
        menu.addItem(refreshItem)
        let editItem = item("Edit aliases…", action: #selector(editAliases))
        editItem.isEnabled = !contexts.isEmpty
        menu.addItem(editItem)
        menu.addItem(item("About KubeBar", action: #selector(about)))
        menu.addItem(item("Quit KubeBar", action: #selector(quit)))
        menu.autoenablesItems = false
        // Items with no action are informational, even with automatic validation disabled.
        for entry in menu.items where entry.action == nil { entry.isEnabled = false }
    }

    @objc private func refresh() {
        guard !busy else { return }
        busy = true
        worker.async { [self] in
            let result = kubectl.run(["config", "view", "-o", "json"])
            var names: [String] = []
            var selected = ""
            var failure: String?
            if result.status != 0 {
                failure = result.error.isEmpty ? "kubectl exited with status \(result.status)." : result.error
            } else if let data = result.output.data(using: .utf8),
                      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                names = (config["contexts"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
                selected = config["current-context"] as? String ?? ""
            } else { failure = "Could not read the Kubernetes configuration returned by kubectl." }
            DispatchQueue.main.async { [self, names, selected, failure] in
                busy = false
                contexts = names
                current = selected
                errorMessage = failure
                rebuildMenu()
            }
        }
    }

    @objc private func switchContext(_ sender: NSMenuItem) {
        guard !busy, let name = sender.representedObject as? String, name != current else { return }
        busy = true
        rebuildMenu()
        worker.async { [self] in
            let result = kubectl.run(["config", "use-context", name])
            DispatchQueue.main.async { [self] in
                busy = false
                if result.status == 0 { refresh() }
                else {
                    errorMessage = result.error.isEmpty ? "Could not switch to \(name)." : result.error
                    rebuildMenu()
                    showError()
                }
            }
        }
    }

    @objc private func editAliases() {
        let alert = NSAlert()
        alert.messageText = "Edit context aliases"
        alert.informativeText = "Choose a display name for each context. Leave an alias blank to show the original name. Your kubeconfig stays unchanged."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 560
        let rowHeight: CGFloat = 76
        let height = CGFloat(contexts.count) * rowHeight
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(height, 380)))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width - 20, height: height))
        var fields: [(String, NSTextField)] = []
        let saved = UserDefaults.standard.dictionary(forKey: "contextAliases") as? [String: String] ?? [:]
        for (index, context) in contexts.enumerated() {
            let y = height - CGFloat(index + 1) * rowHeight
            let label = NSTextField(labelWithString: context)
            label.frame = NSRect(x: 0, y: y + 42, width: width - 24, height: 20)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = context
            label.isSelectable = true
            content.addSubview(label)
            let field = NSTextField(frame: NSRect(x: 0, y: y + 10, width: width - 24, height: 26))
            field.stringValue = saved[context] ?? ""
            field.placeholderString = "Original context name"
            field.setAccessibilityLabel("Alias for \(context)")
            content.addSubview(field)
            fields.append((context, field))
        }
        for index in 0..<max(0, fields.count - 1) {
            fields[index].1.nextKeyView = fields[index + 1].1
        }
        scroll.documentView = content
        content.scroll(NSPoint(x: 0, y: max(0, height - scroll.contentSize.height)))
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = fields.first?.1
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var updated = saved
        for (context, field) in fields {
            updated[context] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        UserDefaults.standard.set(updated, forKey: "contextAliases")
        rebuildMenu()
    }

    @objc private func showError() {
        let alert = NSAlert()
        alert.messageText = "KubeBar couldn't update your context"
        alert.informativeText = errorMessage ?? "No error details available."
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "KubeBar"
        alert.informativeText = "Switch Kubernetes contexts from your menu bar.\n\nUses kubectl and your default ~/.kube/config (or the KUBECONFIG environment inherited at launch). Refreshes every 15 seconds. Switching changes the context used by other kubectl commands sharing that configuration."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
