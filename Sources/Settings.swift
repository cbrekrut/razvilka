import AppKit
import SwiftUI

/// Черновик настроек в окне: поля текстом, проверка только по кнопке «Сохранить».
final class SettingsModel: ObservableObject {
    @Published var host = ""
    @Published var port = ""
    @Published var username = ""
    @Published var password = ""
    @Published var direct = ""
    @Published var autostart = true
    @Published var error: String?
    @Published var neko: NekoImport.Found?
    @Published var imported = false
    let firstRun: Bool

    init(config: ProxyConfig, autostart: Bool, neko: NekoImport.Found?) {
        host = config.host
        port = config.port > 0 ? String(config.port) : ""
        username = config.username
        password = config.password
        direct = config.directDomains.joined(separator: "\n")
        self.autostart = autostart
        firstRun = !config.isComplete
        // Предлагаем перенос, только если в NekoBox другой сервер
        self.neko = (neko.map { $0.host == config.host && $0.port == config.port } ?? true) ? nil : neko
    }

    func importNeko() {
        guard let n = neko else { return }
        host = n.host
        port = String(n.port)
        username = n.username
        password = n.password
        if let d = n.directDomains { direct = d.joined(separator: "\n") }
        imported = true
        error = nil
    }

    /// Настройки из полей или nil с текстом ошибки в error.
    func build(base: ProxyConfig) -> ProxyConfig? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where h.lowercased().hasPrefix(prefix) { h.removeFirst(prefix.count) }
        while h.hasSuffix("/") { h.removeLast() }
        var p = port.trimmingCharacters(in: .whitespaces)
        // Вставили «адрес:порт» целиком в поле адреса
        if p.isEmpty, h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") {
            p = String(h[h.index(after: colon)...])
            h = String(h[..<colon])
        }
        guard !h.isEmpty else { error = "Укажите адрес прокси-сервера"; return nil }
        guard !h.contains(" "), !h.contains("/") else { error = "Адрес сервера выглядит неправильно"; return nil }
        guard let portNumber = Int(p), (1...65535).contains(portNumber) else { error = "Порт — число от 1 до 65535"; return nil }
        var c = base
        c.host = h
        c.port = portNumber
        c.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        c.password = password
        c.directDomains = direct.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        error = nil
        return c
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let n = model.neko, !model.imported {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("В NekoBox есть сервер").font(.headline)
                        Text("\(n.host):\(String(n.port))" + (n.name.isEmpty ? "" : " · \(n.name)"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Взять оттуда") { model.importNeko() }
                        .controlSize(.large)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Прокси-сервер").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Адрес").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        TextField("например, 203.0.113.5", text: $model.host)
                    }
                    GridRow {
                        Text("Порт").foregroundStyle(.secondary)
                        TextField("", text: $model.port).frame(width: 90)
                    }
                    GridRow {
                        Text("Логин").foregroundStyle(.secondary)
                        TextField("если нужен", text: $model.username)
                    }
                    GridRow {
                        Text("Пароль").foregroundStyle(.secondary)
                        SecureField("если нужен", text: $model.password)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Напрямую, без прокси").font(.headline)
                TextEditor(text: $model.direct)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 92)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                Text("По одному в строке: «.ru» — все сайты в зоне .ru, «yandex.com» — сайт со всеми поддоменами. Сайты на российских серверах идут напрямую и без этого списка.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Запускать при входе в систему", isOn: $model.autostart)

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Отмена", action: onCancel).keyboardShortcut(.cancelAction)
                Button(model.firstRun ? "Сохранить и включить" : "Сохранить", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: SettingsModel
    var onClose: (() -> Void)?

    init(model: SettingsModel, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        let host = NSHostingView(rootView: SettingsView(model: model, onSave: onSave, onCancel: onCancel))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Развилка — настройки"
        window.contentView = host
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// --settings-snapshot <png> [--neko] [--error] [--filled]: окно настроек в картинку без показа на экране.
@MainActor func renderSettingsSnapshot(neko: Bool, error: Bool, filled: Bool) -> Data? {
    var config = ProxyConfig()
    if filled {
        config.host = "203.0.113.5"
        config.port = 8080
        config.username = "user"
        config.password = "password"
    }
    let found = neko ? NekoImport.Found(name: "Мой сервер", host: "203.0.113.5", port: 8080, username: "u", password: "p", directDomains: [".ru"]) : nil
    let model = SettingsModel(config: config, autostart: true, neko: filled ? nil : found)
    if error { model.error = "Порт — число от 1 до 65535" }
    let view = SettingsView(model: model, onSave: {}, onCancel: {})
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: image)
    return image.representation(using: .png, properties: [:])
}
