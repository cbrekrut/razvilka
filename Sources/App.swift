import AppKit
import SwiftUI

func runApp(_ args: [String]) {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
}

/// Автозапуск: файл в ~/Library/LaunchAgents. launchd перезапустит приложение, если оно упадёт
/// (иначе системный прокси указывал бы в пустоту и интернет пропал бы), но не после «Выйти».
enum LoginItem {
    static func plistData(executable: String) -> Data {
        let plist: [String: Any] = [
            "Label": Paths.bundleID,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: Paths.launchAgent.path) }

    static func setEnabled(_ on: Bool, executable: String) throws {
        let url = Paths.launchAgent
        if on {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plistData(executable: executable).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// NekoBox тоже управляет системным прокси и при выходе выключает его: вдвоём им не ужиться.
enum NekoBox {
    static func running() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            let exe = app.executableURL?.lastPathComponent.lowercased() ?? ""
            return id.contains("nekoray") || id.contains("nekobox") || exe == "nekoray" || exe == "nekobox"
        }
    }

    /// Просим закрыться, через 8 с закрываем принудительно. true — закрылся.
    static func quit(_ app: NSRunningApplication) -> Bool {
        app.terminate()
        for _ in 0..<40 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.2) }
        if !app.isTerminated { app.forceTerminate() }
        for _ in 0..<15 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.2) }
        Thread.sleep(forTimeInterval: 0.5)   // NekoBox при выходе ещё сбрасывает системный прокси
        return app.isTerminated
    }
}

/// Значок в строке меню: развилка со стрелками, как на иконке приложения. Шаблонная картинка:
/// macOS сама красит её под светлую и тёмную строку меню. Выключено — бледная, беда — с точкой.
enum Glyph {
    private static var cache: [String: NSImage] = [:]

    static func image(for state: MenuState, tone: MenuText.Tone) -> NSImage {
        if state.busy != nil { return image(alpha: 0.55, badge: false) }
        return image(alpha: state.on ? 1 : 0.38, badge: tone == .warning)
    }

    static func image(alpha: CGFloat, badge: Bool) -> NSImage {
        let key = "\(alpha)-\(badge)"
        if let cached = cache[key] { return cached }
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Прозрачность на всю развилку разом, иначе стрелки темнеют там, где ложатся на линии
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setAlpha(alpha)
            ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.set()
            let fork = NSPoint(x: 9, y: 7.5)
            let ends = [NSPoint(x: 4.6, y: 13.2), NSPoint(x: 13.4, y: 13.2)]
            let road = NSBezierPath()
            road.lineWidth = 1.9
            road.lineCapStyle = .round
            road.lineJoinStyle = .round
            road.move(to: NSPoint(x: 9, y: 1.8))
            road.line(to: fork)
            road.line(to: ends[0])
            road.move(to: fork)
            road.line(to: ends[1])
            road.stroke()
            for end in ends {
                let dx = end.x - fork.x, dy = end.y - fork.y
                let len = (dx * dx + dy * dy).squareRoot()
                let d = (dx / len, dy / len), p = (dy / len, -dx / len)
                let head = NSBezierPath()
                head.move(to: NSPoint(x: end.x + d.0 * 3.6, y: end.y + d.1 * 3.6))
                head.line(to: NSPoint(x: end.x - d.0 * 0.6 + p.0 * 2.8, y: end.y - d.1 * 0.6 + p.1 * 2.8))
                head.line(to: NSPoint(x: end.x - d.0 * 0.6 - p.0 * 2.8, y: end.y - d.1 * 0.6 - p.1 * 2.8))
                head.close()
                head.fill()
            }
            ctx?.endTransparencyLayer()
            ctx?.setAlpha(1)
            if badge {
                NSColor.black.set()
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Развилка"
        cache[key] = img
        return img
    }

    /// --glyph-snapshot: все состояния значка рядом, крупно, на светлом и тёмном фоне.
    static func snapshot() -> Data? {
        let states: [(CGFloat, Bool)] = [(1, false), (1, true), (0.38, false), (0.38, true), (0.55, false)]
        let scale: CGFloat = 6, cell: CGFloat = 18 * scale + 24
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell) * states.count, pixelsHigh: Int(cell) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        for (row, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            bg.setFill()
            NSRect(x: 0, y: CGFloat(row) * cell, width: cell * CGFloat(states.count), height: cell).fill()
            for (i, st) in states.enumerated() {
                let tinted = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                    image(alpha: st.0, badge: st.1).draw(in: r)
                    fg.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: CGFloat(i) * cell + 12, y: CGFloat(row) * cell + 12, width: 18 * scale, height: 18 * scale))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    private var core: ProxyCore!
    private var config = ProxyConfig()
    private var statusItem: NSStatusItem!
    private var state = MenuState()
    private var listening = false
    private var lastSample: (up: UInt64, down: UInt64, at: Date)?
    private var lastRestore = Date.distantPast
    private var tick = 0
    private var timer: Timer?
    private var settings: SettingsWindow?
    private var checking = false
    private var shutDown = false
    private var signalSources: [DispatchSourceSignal] = []

    private let statusLine = NSMenuItem()
    private let problemLine = NSMenuItem()
    private let speedLine = NSMenuItem()
    private let restoreItem = NSMenuItem(title: "Вернуть настройки прокси", action: #selector(restoreSystem), keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Включить", action: #selector(toggle), keyEquivalent: "")
    private let rulesItem = NSMenuItem(title: "Российские сайты напрямую", action: #selector(setRules), keyEquivalent: "")
    private let allItem = NSMenuItem(title: "Всё через прокси", action: #selector(setAll), keyEquivalent: "")
    private let checkItem = NSMenuItem(title: "Проверить связь и скорость", action: #selector(runCheck), keyEquivalent: "")

    private var ours: SystemProxy.Endpoint { .init(host: "127.0.0.1", port: config.localPort) }

    // MARK: Запуск и выход

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.first?.activate()
            shutDown = true   // второй экземпляр: системные настройки не трогаем
            exit(0)
        }
        installEditMenu()
        config = ConfigFile.load() ?? ProxyConfig()
        core = ProxyCore(config: config, russia: CIDRSet.russia())
        core.onProblem = { [weak self] p in
            DispatchQueue.main.async {
                self?.state.problem = p
                self?.refresh()
            }
        }
        buildStatusItem()
        handleSignals()
        state.configured = config.isComplete
        state.server = config.host
        state.mode = config.mode
        refresh()

        core.start(port: UInt16(config.localPort)) { [weak self] error in
            DispatchQueue.main.async { self?.listenerStarted(error) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
        RunLoop.main.add(timer!, forMode: .common)   // скорость обновляется и при открытом меню
        if !config.isComplete { openSettings() }
    }

    private func listenerStarted(_ error: Error?) {
        if let error {
            listening = false
            state.listenError = "Порт \(config.localPort) занят другой программой"
            Log.write("не удалось открыть порт \(config.localPort): \(error)")
            refresh()
            return
        }
        listening = true
        state.listenError = nil
        Log.write("запущено, порт \(config.localPort)")
        if config.enabled && config.isComplete {
            if NekoBox.running() != nil {
                state.nekoBlocking = true   // чужую программу без спроса не закрываем
                refresh()
            } else {
                turnOn()
            }
        } else if SystemProxy.currentHTTPS() == ours {
            // Остались настройки от прошлого запуска, который не успел их убрать
            DispatchQueue.global().async { [port = config.localPort] in SystemProxy.disable(port: port) }
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    /// Убрать системный прокси до выхода, иначе программы остались бы без интернета.
    private func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        if state.on { SystemProxy.disable(port: config.localPort) }
        core?.stop()
    }

    private func handleSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Меню

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = true   // без действия: обычный цвет, щелчок просто закрывает меню
        problemLine.isEnabled = true
        speedLine.isEnabled = false
        for item in [restoreItem, toggleItem, rulesItem, allItem, checkItem] { item.target = self }
        menu.addItem(statusLine)
        menu.addItem(problemLine)
        menu.addItem(speedLine)
        menu.addItem(restoreItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(rulesItem)
        menu.addItem(allItem)
        menu.addItem(.separator())
        menu.addItem(checkItem)
        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refresh() {
        let status = MenuText.status(state)
        let dotColor: NSColor = status.tone == .good ? .systemGreen : status.tone == .warning ? .systemOrange : .tertiaryLabelColor
        let title = NSMutableAttributedString(string: "●  ", attributes: [.foregroundColor: dotColor, .font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: status.text, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]))
        statusLine.attributedTitle = title

        if let p = MenuText.problem(state) {
            problemLine.isHidden = false
            problemLine.attributedTitle = NSAttributedString(string: "⚠︎  " + p, attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.menuFont(ofSize: 0)])
        } else {
            problemLine.isHidden = true
        }
        if let s = MenuText.speed(state) {
            speedLine.isHidden = false
            speedLine.title = s
        } else {
            speedLine.isHidden = true
        }
        restoreItem.isHidden = !(state.on && state.hijackedBy != nil)
        toggleItem.title = MenuText.toggle(state)
        toggleItem.isEnabled = state.busy == nil && listening
        rulesItem.state = config.mode == .rules ? .on : .off
        allItem.state = config.mode == .all ? .on : .off
        checkItem.title = checking ? "Проверяю…" : "Проверить связь и скорость"
        checkItem.isEnabled = !checking && listening && config.isComplete

        statusItem.button?.image = Glyph.image(for: state, tone: status.tone)
        statusItem.button?.toolTip = "Развилка: " + status.text
    }

    private func everySecond() {
        let snap = core.stats.snapshot
        let now = Date()
        if let last = lastSample {
            let dt = max(now.timeIntervalSince(last.at), 0.001)
            state.downBytesPerSec = Double(snap.down &- last.down) / dt
            state.upBytesPerSec = Double(snap.up &- last.up) / dt
        }
        lastSample = (snap.up, snap.down, now)
        tick += 1
        if tick % 3 == 0 { watchSystemProxy() }
        refresh()
    }

    /// Следим, чтобы системный прокси указывал на нас, пока включено.
    private func watchSystemProxy() {
        guard state.on, state.busy == nil else { return }
        let current = SystemProxy.currentHTTPS()
        if current == ours {
            state.hijackedBy = nil
        } else if current == nil {
            // Кто-то выключил (например, NekoBox при выходе или смена сети): возвращаем, не чаще раза в 30 с
            state.hijackedBy = nil
            if Date().timeIntervalSince(lastRestore) > 30 {
                lastRestore = Date()
                Log.write("системный прокси оказался выключен, включаю снова")
                DispatchQueue.global().async { [port = config.localPort] in SystemProxy.enable(port: port) }
            }
        } else if let current {
            state.hijackedBy = "\(current.host):\(current.port)"
        }
    }

    // MARK: Действия

    @objc private func toggle() {
        state.on ? turnOff() : turnOn(askAboutNeko: true)
    }

    private func turnOn(askAboutNeko: Bool = false) {
        guard state.busy == nil else { return }
        guard config.isComplete else { openSettings(); return }
        guard listening else { return }
        var neko: NSRunningApplication?
        if let running = NekoBox.running() {
            guard askAboutNeko else { state.nekoBlocking = true; refresh(); return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "NekoBox ещё работает"
            alert.informativeText = "Он тоже управляет настройками прокси и при выходе выключит их. Закрыть NekoBox и включить Развилку?"
            alert.addButton(withTitle: "Закрыть NekoBox и включить")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            neko = running
        }
        state.busy = true
        state.nekoBlocking = false
        refresh()
        let port = config.localPort
        DispatchQueue.global().async {
            if let neko, !NekoBox.quit(neko) { Log.write("NekoBox не закрылся") }
            SystemProxy.enable(port: port)
            DispatchQueue.main.async {
                self.state.busy = nil
                self.state.on = true
                self.state.hijackedBy = nil
                self.lastRestore = Date()
                self.config.enabled = true
                self.save()
                self.refresh()
            }
        }
    }

    private func turnOff() {
        guard state.busy == nil else { return }
        state.busy = false
        refresh()
        let port = config.localPort
        DispatchQueue.global().async {
            SystemProxy.disable(port: port)
            DispatchQueue.main.async {
                self.state.busy = nil
                self.state.on = false
                self.state.hijackedBy = nil
                self.config.enabled = false
                self.save()
                self.refresh()
            }
        }
    }

    @objc private func restoreSystem() {
        state.hijackedBy = nil
        state.busy = true
        refresh()
        DispatchQueue.global().async { [port = config.localPort] in
            SystemProxy.enable(port: port)
            DispatchQueue.main.async {
                self.state.busy = nil
                self.refresh()
            }
        }
    }

    @objc private func setRules() { setMode(.rules) }
    @objc private func setAll() { setMode(.all) }

    private func setMode(_ mode: RouteMode) {
        config.mode = mode
        state.mode = mode
        core.apply(config)
        save()
        refresh()
    }

    private func save() {
        do { try ConfigFile.save(config) } catch { Log.write("не удалось сохранить настройки: \(error)") }
    }

    @objc private func runCheck() {
        checking = true
        refresh()
        let port = config.localPort
        Task {
            let report = await Checker.run(proxyPort: port)
            await MainActor.run {
                self.checking = false
                self.refresh()
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = report.error == nil ? "Связь через прокси есть" : "Связи через прокси нет"
                alert.informativeText = report.summary
                alert.alertStyle = report.error == nil ? .informational : .warning
                alert.runModal()
            }
        }
    }

    @objc private func openSettings() {
        if let settings {
            settings.show()
            return
        }
        let model = SettingsModel(config: config, autostart: LoginItem.isEnabled || !config.isComplete, neko: NekoImport.find())
        let window = SettingsWindow(model: model, onSave: { [weak self] in self?.saveSettings() },
                                    onCancel: { [weak self] in self?.settings?.window.close() })
        window.onClose = { [weak self] in self?.settings = nil }
        settings = window
        window.show()
    }

    private func saveSettings() {
        guard let window = settings else { return }
        let model = window.model
        guard let fresh = model.build(base: config) else { return }
        let firstRun = !config.isComplete
        config = fresh
        do {
            try ConfigFile.save(config)
        } catch {
            model.error = "Не удалось сохранить: \(error.localizedDescription)"
            return
        }
        if let exe = Bundle.main.executablePath {
            try? LoginItem.setEnabled(model.autostart, executable: exe)
        }
        core.apply(config)
        state.configured = config.isComplete
        state.server = config.host
        window.window.close()
        refresh()
        if firstRun && !state.on { turnOn(askAboutNeko: true) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Без меню «Правка» в окне не работают ⌘C / ⌘V.
    private func installEditMenu() {
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Развилка", action: nil, keyEquivalent: ""))
        main.addItem(item)
        NSApp.mainMenu = main
    }
}
