import AppKit
import GingerCore
import ServiceManagement

@main
struct Ginger {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ConfigurationStore.standard
    private var configuration = Configuration()
    private var rotation = Rotation()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var outputs: [String: ScriptOutput] = [:]
    private var errors: [String: String] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var running = Set<String>()
    private var configurationError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        reload()
        timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }

    private var availableWidgets: [WidgetConfiguration] {
        configuration.widgets.filter { store.scriptExists($0.id) }
    }

    @objc private func reload() {
        do {
            configuration = try store.load()
            configurationError = nil
            lastAttempt = [:]
        } catch { configurationError = "Configuration: \(error.localizedDescription)" }
        tick()
    }

    @objc private func tick() {
        let now = Date()
        for widget in availableWidgets where widget.enabled && !running.contains(widget.id) {
            if lastAttempt[widget.id].map({ now.timeIntervalSince($0) < widget.refreshSeconds }) != true {
                refresh(widget, now: now)
            }
        }
        let id = rotation.update(widgets: availableWidgets, now: now)
        guard let id, let widget = configuration.widgets.first(where: { $0.id == id }) else {
            statusItem.button?.title = configurationError == nil ? "Ginger" : "Ginger ⚠️"
            statusItem.button?.toolTip = configurationError ?? "No enabled widgets. Add scripts in ~/.ginger/widgets."
            return
        }
        let warning = errors[id] == nil && configurationError == nil ? "" : " ⚠️"
        statusItem.button?.title = (outputs[id]?.title ?? "\(widget.name) …") + warning
        statusItem.button?.toolTip = configurationError ?? errors[id] ?? outputs[id]?.detail ?? "Refreshing…"
    }

    private func refresh(_ widget: WidgetConfiguration, now: Date) {
        running.insert(widget.id)
        lastAttempt[widget.id] = now
        Task {
            do {
                let output = try await ScriptRunner.run(
                    script: store.scriptsDirectory.appendingPathComponent(widget.id),
                    directory: store.directory,
                    environment: widget.environment)
                if configuration.widgets.first(where: { $0.id == widget.id }) == widget {
                    outputs[widget.id] = output
                    errors[widget.id] = nil
                }
            } catch {
                if configuration.widgets.first(where: { $0.id == widget.id }) == widget {
                    errors[widget.id] = error.localizedDescription
                }
            }
            running.remove(widget.id)
            tick()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let configurationError { menu.addItem(info(configurationError)) }
        for widget in configuration.widgets {
            let item = NSMenuItem(title: widget.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: widget.name)
            submenu.autoenablesItems = false
            item.submenu = submenu
            menu.addItem(item)
            let enabled = add("Enabled", action: #selector(toggleWidget(_:)), to: submenu, representedObject: widget.id)
            enabled.state = widget.enabled ? .on : .off
            let show = add("Show now", action: #selector(showWidget(_:)), to: submenu, representedObject: widget.id)
            show.isEnabled = widget.enabled && store.scriptExists(widget.id)
            submenu.addItem(info(outputs[widget.id]?.detail ?? "No output yet."))
            if let output = outputs[widget.id] { addOutputLinks(output, to: submenu) }
            if let error = errors[widget.id] { submenu.addItem(info("⚠️ \(error)")) }
            if !store.scriptExists(widget.id) { submenu.addItem(info("Script is missing or is not executable.")) }
            submenu.addItem(.separator())
            intervalMenu(widget, key: "displaySeconds", title: "Display duration", values: [5, 10, 15, 30, 60], to: submenu)
            intervalMenu(widget, key: "refreshSeconds", title: "Refresh interval", values: [30, 60, 300, 900, 1800, 3600], to: submenu)
            add("Edit variables…", action: #selector(editVariables(_:)), to: submenu, representedObject: widget.id)
        }
        menu.addItem(.separator())
        add("Refresh now", action: #selector(refreshAll), to: menu)
        add("Reload scripts and configuration", action: #selector(reload), to: menu)
        add("Open widget folder", action: #selector(openFolder), to: menu)
        add("Edit configuration…", action: #selector(editConfiguration), to: menu)
        menu.addItem(.separator())
        addStartAtLogin(to: menu, status: SMAppService.mainApp.status)
        add("Quit Ginger", action: #selector(quit), to: menu)
    }

    func addStartAtLogin(to menu: NSMenu, status: SMAppService.Status) {
        let loginItem = add("Start at login", action: #selector(toggleStartAtLogin), to: menu)
        switch status {
        case .enabled:
            loginItem.state = .on
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Start at login (approval required)"
            loginItem.toolTip = "Registration needs approval. Click to remove the registration."
            add("Approve in System Settings…", action: #selector(openLoginItemSettings), to: menu)
        case .notRegistered, .notFound:
            // A new app can have no login item record until its first registration.
            loginItem.state = .off
        @unknown default:
            loginItem.isEnabled = false
        }
    }

    func addOutputLinks(_ output: ScriptOutput, to menu: NSMenu) {
        for url in output.links {
            let item = add("Open \(url.host ?? "link")", action: #selector(openOutputLink(_:)), to: menu,
                           representedObject: url)
            item.toolTip = url.absoluteString
        }
    }

    @objc private func openOutputLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: String(title.prefix(240)), action: nil, keyEquivalent: "")
        item.toolTip = title
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu,
                     representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        menu.addItem(item)
        return item
    }

    private func intervalMenu(_ widget: WidgetConfiguration, key: String, title: String,
                              values: [Int], to menu: NSMenu) {
        let current = key == "displaySeconds" ? widget.displaySeconds : widget.refreshSeconds
        let parent = NSMenuItem(title: "\(title): \(formatSeconds(current))", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        parent.submenu = submenu
        menu.addItem(parent)
        for value in values {
            let item = add(formatSeconds(Double(value)), action: #selector(setInterval(_:)), to: submenu,
                           representedObject: [widget.id, key, String(value)])
            item.state = current == Double(value) ? .on : .off
        }
        add("Custom…", action: #selector(setInterval(_:)), to: submenu,
            representedObject: [widget.id, key, "custom"])
    }

    private func formatSeconds(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 60) == 0
            ? "\(String(format: "%g", value / 60)) min" : "\(String(format: "%g", value)) sec"
    }

    private func changeWidget(_ id: String, update: (inout WidgetConfiguration) -> Void) {
        guard let index = configuration.widgets.firstIndex(where: { $0.id == id }) else { return }
        var changed = configuration
        update(&changed.widgets[index])
        do {
            try store.save(changed)
            configuration = changed
            configurationError = nil
            lastAttempt[id] = nil
        } catch { configurationError = error.localizedDescription }
        tick()
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        changeWidget(id) { $0.enabled.toggle() }
    }

    @objc private func showWidget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        rotation.select(id, now: Date())
        tick()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? [String], choice.count == 3,
              let widget = configuration.widgets.first(where: { $0.id == choice[0] }) else { return }
        var text = choice[2]
        if text == "custom" {
            let alert = NSAlert()
            alert.messageText = choice[1] == "displaySeconds" ? "Display duration" : "Refresh interval"
            alert.informativeText = "Enter the interval in seconds. The minimum is 1 second."
            let value = choice[1] == "displaySeconds" ? widget.displaySeconds : widget.refreshSeconds
            let input = NSTextField(string: String(value))
            input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = input
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            text = input.stringValue
        }
        guard let seconds = Double(text), seconds.isFinite, seconds >= 1 else {
            let alert = NSAlert()
            alert.messageText = "Enter a number of at least 1 second."
            alert.runModal()
            return
        }
        changeWidget(choice[0]) {
            if choice[1] == "displaySeconds" { $0.displaySeconds = seconds } else { $0.refreshSeconds = seconds }
        }
    }

    @objc private func editVariables(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let widget = configuration.widgets.first(where: { $0.id == id }) else { return }
        guard !widget.environment.isEmpty else { editConfiguration(); return }
        let alert = NSAlert()
        alert.messageText = "Variables for \(widget.name)"
        alert.informativeText = "These values apply only to this widget. Add variable names in config.json."
        let keys = widget.environment.keys.sorted()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: keys.count * 54))
        var fields: [String: NSTextField] = [:]
        for (index, key) in keys.enumerated() {
            let verticalPosition = (keys.count - index - 1) * 54
            let label = NSTextField(labelWithString: key)
            label.frame = NSRect(x: 0, y: verticalPosition + 28, width: 400, height: 20)
            let field = NSTextField(string: widget.environment[key] ?? "")
            field.frame = NSRect(x: 0, y: verticalPosition + 2, width: 400, height: 24)
            fields[key] = field
            view.addSubview(label)
            view.addSubview(field)
        }
        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeWidget(id) { widget in
            for (key, field) in fields { widget.environment[key] = field.stringValue }
        }
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                throw GingerError("macOS returned an unknown login item status.")
            }
            if service.status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = "Approve start at login"
                alert.informativeText = "Allow Ginger in System Settings → General → Login Items."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                NSApplication.shared.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { openLoginItemSettings() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change start at login"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open System Settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { openLoginItemSettings() }
        }
    }

    @objc private func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func refreshAll() { lastAttempt = [:]; tick() }
    @objc private func openFolder() { NSWorkspace.shared.open(store.scriptsDirectory) }
    @objc private func editConfiguration() { NSWorkspace.shared.open(store.file) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
