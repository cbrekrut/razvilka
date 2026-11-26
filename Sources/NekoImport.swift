import Foundation

/// Перенос сервера и списка «напрямую» из NekoBox. Файлы NekoBox только читаются.
enum NekoImport {
    struct Found: Equatable {
        var name: String
        var host: String
        var port: Int
        var username: String
        var password: String
        var directDomains: [String]?
    }

    /// Папка настроек NekoBox. RAZVILKA_NEKO_DIR подменяет её для проверок.
    static var defaultDir: URL {
        if let custom = ProcessInfo.processInfo.environment["RAZVILKA_NEKO_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/nekoray/config")
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Первый HTTP-сервер без TLS из профилей NekoBox (другие виды наше приложение не умеет). nil — подходящего нет.
    static func find(in dir: URL = defaultDir) -> Found? {
        let profiles = dir.appendingPathComponent("profiles")
        guard let files = try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else { return nil }
        let sorted = files.filter { $0.pathExtension == "json" }
            .sorted { (Int($0.deletingPathExtension().lastPathComponent) ?? .max) < (Int($1.deletingPathExtension().lastPathComponent) ?? .max) }
        for file in sorted {
            guard let profile = json(file), (profile["type"] as? String)?.lowercased() == "http",
                  let bean = profile["bean"] as? [String: Any],
                  let host = bean["addr"] as? String, !host.isEmpty,
                  let port = bean["port"] as? Int, (1...65535).contains(port) else { continue }
            let stream = bean["stream"] as? [String: Any] ?? [:]
            if let sec = stream["sec"] as? String, !sec.isEmpty, sec.lowercased() != "none" { continue }
            return Found(name: bean["name"] as? String ?? "",
                         host: host, port: port,
                         username: bean["username"] as? String ?? "",
                         password: bean["password"] as? String ?? "",
                         directDomains: directDomains(in: dir))
        }
        return nil
    }

    /// Список «напрямую» из действующих правил NekoBox, без строк, которые наше приложение не понимает.
    static func directDomains(in dir: URL) -> [String]? {
        let active = (json(dir.appendingPathComponent("groups/nekobox.json"))?["active_routing"] as? String) ?? "Default"
        guard let route = json(dir.appendingPathComponent("routes_box").appendingPathComponent(active)),
              let text = route["direct_domain"] as? String else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { RouteRules.parseEntry($0) != nil }
        return lines.isEmpty ? nil : lines
    }
}
