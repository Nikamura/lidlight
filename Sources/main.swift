// Lidlight — menu bar toggle for `pmset -a disablesleep`, with a timer.
//
// Privilege model: a one-time admin prompt installs /etc/sudoers.d/lidlight,
// which lets the current user run exactly two commands without a password:
//   /usr/bin/pmset -a disablesleep 0
//   /usr/bin/pmset -a disablesleep 1
//
// Safety: sleep is re-enabled when the timer ends, on Quit, and when the
// battery drops to the configured floor while unplugged. A pending end time
// is persisted, so a crash/restart still turns it off on next launch.

import AppKit
import IOKit.ps
import ServiceManagement

let sudoersPath = "/etc/sudoers.d/lidlight"
let batteryFloor = 10 // percent; auto-off when on battery at or below this
let endDateKey = "endDate"           // Date, or absent
let indefiniteKey = "indefinite"     // Bool

// MARK: - System helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func sleepDisabled() -> Bool {
    let out = run("/usr/bin/pmset", ["-g"]).out
    for line in out.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
    }
    return false
}

func setSleepDisabled(_ on: Bool) -> Bool {
    run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
}

func installSudoersRule() -> Bool {
    let user = NSUserName()
    guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
    let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    let script = """
    set -e; t=$(mktemp); printf '%s\\n' '\(rule)' > "$t"; \
    /usr/sbin/visudo -cf "$t" >/dev/null; \
    /usr/bin/install -m 0440 -o root -g wheel "$t" \(sudoersPath); rm -f "$t"
    """
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var err: NSDictionary?
    NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
    return err == nil
}

/// (percent, onBattery) or nil if there is no battery.
func batteryState() -> (Int, Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        return (cur * 100 / max, onBattery)
    }
    return nil
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    var ticker: Timer?

    var endDate: Date? {
        get { defaults.object(forKey: endDateKey) as? Date }
        set { defaults.set(newValue, forKey: endDateKey) }
    }
    var indefinite: Bool {
        get { defaults.bool(forKey: indefiniteKey) }
        set { defaults.set(newValue, forKey: indefiniteKey) }
    }
    var isOn = false

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu

        // Reconcile persisted state with the system.
        isOn = sleepDisabled()
        if let end = endDate {
            if end <= Date() { turnOff() } else if !isOn { endDate = nil }
        } else if isOn && !indefinite {
            indefinite = true // was enabled outside the app; treat as "until turned off"
        }
        if !isOn { indefinite = false }

        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        ticker?.tolerance = 5
        refresh()
    }

    func applicationWillTerminate(_ n: Notification) {
        if isOn { _ = setSleepDisabled(false); endDate = nil; indefinite = false }
    }

    // MARK: Actions

    /// Applies the setting, running the one-time sudoers setup if needed. Interactive: may show dialogs.
    func apply(_ on: Bool) -> Bool {
        if setSleepDisabled(on) { return true }
        if confirmSetup(), installSudoersRule(), setSleepDisabled(on) { return true }
        alert(on ? "Couldn’t enable" : "Couldn’t turn off",
              "Lidlight needs a one-time admin approval to run pmset.\n\nManual fallback: sudo pmset -a disablesleep \(on ? 1 : 0)")
        return false
    }

    func turnOn(minutes: Int?) {
        guard apply(true) else { return }
        isOn = true
        if let m = minutes {
            endDate = Date().addingTimeInterval(TimeInterval(m * 60)); indefinite = false
        } else {
            endDate = nil; indefinite = true
        }
        refresh()
    }

    /// Non-interactive off (timer, battery, launch). Falls back to a notification if not set up.
    func turnOff() {
        if setSleepDisabled(false) || !sleepDisabled() {
            isOn = false; endDate = nil; indefinite = false
        } else {
            notify("Couldn’t re-enable sleep", "Open Lidlight → Turn off to finish setup.")
        }
        refresh()
    }

    @objc func off() {
        if apply(false) { isOn = false; endDate = nil; indefinite = false }
        refresh()
    }

    func tick() {
        guard isOn else { return }
        if let end = endDate, end <= Date() { turnOff(); notify("Sleep re-enabled", "Timer finished."); return }
        if let (pct, onBattery) = batteryState(), onBattery, pct <= batteryFloor {
            turnOff(); notify("Sleep re-enabled", "Battery at \(pct)%."); return
        }
        if !sleepDisabled() { isOn = false; endDate = nil; indefinite = false } // changed externally
        refresh()
    }

    @objc func pick(_ s: NSMenuItem) { turnOn(minutes: s.tag == 0 ? nil : s.tag) }
    @objc func quit() {
        if isOn, apply(false) { isOn = false; endDate = nil; indefinite = false }
        NSApp.terminate(nil)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn’t change login item", error.localizedDescription)
        }
    }

    @objc func custom() {
        let a = NSAlert()
        a.messageText = "Keep awake for how many minutes?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 45"
        a.accessoryView = field
        a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn,
              let m = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), m > 0, m <= 24 * 60 * 7 else { return }
        turnOn(minutes: m)
    }

    @objc func extend(_ s: NSMenuItem) {
        guard let end = endDate else { return }
        endDate = max(end, Date()).addingTimeInterval(TimeInterval(s.tag * 60))
        refresh()
    }

    // MARK: UI

    func refresh() {
        let name = isOn ? "sun.max.fill" : "moon.zzz"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: isOn ? "Awake" : "Normal sleep")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.title = isOn ? (endDate.map { " " + short($0) } ?? " ∞") : ""
        item.button?.imagePosition = .imageLeading
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if !isOn { status = "Sleep: normal" }
        else if let end = endDate {
            let f = DateFormatter(); f.timeStyle = .short
            status = "Awake — \(long(end)) left (until \(f.string(from: end)))"
        } else { status = "Awake — until turned off" }
        let s = NSMenuItem(title: status, action: nil, keyEquivalent: ""); s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())

        for (title, m) in [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            let i = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: ""); i.tag = m; i.target = self
            menu.addItem(i)
        }
        let c = NSMenuItem(title: "Custom…", action: #selector(custom), keyEquivalent: ""); c.target = self
        menu.addItem(c)
        let inf = NSMenuItem(title: "Until turned off", action: #selector(pick(_:)), keyEquivalent: ""); inf.tag = 0; inf.target = self
        menu.addItem(inf)

        if isOn {
            menu.addItem(.separator())
            if endDate != nil {
                for (title, m) in [("+15 minutes", 15), ("+1 hour", 60)] {
                    let i = NSMenuItem(title: title, action: #selector(extend(_:)), keyEquivalent: ""); i.tag = m; i.target = self
                    menu.addItem(i)
                }
            }
            let o = NSMenuItem(title: "Turn off", action: #selector(off), keyEquivalent: "o"); o.target = self
            menu.addItem(o)
        }

        menu.addItem(.separator())
        let note = NSMenuItem(title: "Auto-off on battery ≤ \(batteryFloor)%", action: nil, keyEquivalent: ""); note.isEnabled = false
        menu.addItem(note)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let q = NSMenuItem(title: "Quit (re-enables sleep)", action: #selector(quit), keyEquivalent: "q"); q.target = self
        menu.addItem(q)
    }

    func short(_ end: Date) -> String {
        let m = max(0, Int(ceil(end.timeIntervalSinceNow / 60)))
        return m >= 60 ? "\(m / 60)h\(m % 60 > 0 ? String(format: "%02d", m % 60) : "")" : "\(m)m"
    }

    func long(_ end: Date) -> String {
        let m = max(0, Int(ceil(end.timeIntervalSinceNow / 60)))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    func confirmSetup() -> Bool {
        let a = NSAlert()
        a.messageText = "One-time setup"
        a.informativeText = "Lidlight will ask for your admin password once to allow your user to run “pmset -a disablesleep 0/1” without a password (rule saved in \(sudoersPath))."
        a.addButton(withTitle: "Continue"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    func notify(_ title: String, _ text: String) {
        // Lightweight notification without UserNotifications entitlement fuss.
        run("/usr/bin/osascript", ["-e", "display notification \"\(text)\" with title \"Lidlight\" subtitle \"\(title)\""])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
