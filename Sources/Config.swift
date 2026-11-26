import Foundation

/// Как делить трафик между прямым выходом и сервером.
enum RouteMode: String, Codable {
    case rules   // российские сайты и адреса напрямую, остальное через сервер
    case all     // всё через сервер (кроме домашней сети)
}

/// Всё, что приложение помнит между запусками. Лежит в config.json с правами только для владельца:
/// там пароль от прокси-сервера (так же он хранился у NekoBox).
struct ProxyConfig: Codable, Equatable {
    var host = ""
    var port = 0
    var username = ""
    var password = ""
    var mode = RouteMode.rules
    var directDomains = ProxyConfig.defaultDirectDomains
    var localPort = 2090
    var enabled = false

    static let defaultDirectDomains = [".ru", ".su", ".рф"]

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }

    /// Смена сервера или правил: кэш «российский / нет» надо сбросить.
    func sameUpstream(as other: ProxyConfig) -> Bool {
        host == other.host && port == other.port && username == other.username && password == other.password
    }

    init() {}

    // Любое поле может отсутствовать (файл старой версии, ручная правка): берём значение по умолчанию
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxyConfig()
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? d.host
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? d.port
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? d.username
        password = (try? c.decodeIfPresent(String.self, forKey: .password)) ?? d.password
        mode = (try? c.decodeIfPresent(RouteMode.self, forKey: .mode)) ?? d.mode
        directDomains = (try? c.decodeIfPresent([String].self, forKey: .directDomains)) ?? d.directDomains
        localPort = (try? c.decodeIfPresent(Int.self, forKey: .localPort)) ?? d.localPort
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        if !(1024...65535).contains(localPort) { localPort = d.localPort }
    }
}

enum Paths {
    static let bundleID = "io.github.cbrekrut.razvilka"

    /// Папка с config.json и журналом. RAZVILKA_DIR подменяет её для проверок.
    static var dataDir: URL {
        if let custom = ProcessInfo.processInfo.environment["RAZVILKA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Razvilka", isDirectory: true)
    }

    static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    static var logFile: URL { dataDir.appendingPathComponent("proxy.log") }

    static var launchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }
}

enum ConfigFile {
    /// nil: файла нет или он не читается.
    static func load(_ url: URL = Paths.configFile) -> ProxyConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProxyConfig.self, from: data)
    }

    static func save(_ config: ProxyConfig, to url: URL = Paths.configFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Короткий журнал событий (включение, ошибки сервера). Адреса сайтов сюда не пишутся.
enum Log {
    private static let lock = NSLock()
    static var echo = false   // --serve: дублировать в stdout для проверок

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = "\(stamp) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if echo {
            FileHandle.standardOutput.write(Data("log \(message)\n".utf8))
        }
        let url = Paths.logFile
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
