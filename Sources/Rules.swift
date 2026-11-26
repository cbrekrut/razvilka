import Foundation

/// Куда отправить соединение. lookup: по имени не понять, надо узнать, где сервер сайта.
enum Decision: Equatable {
    case direct, proxy, lookup
}

/// Решение после проверки адреса сайта.
enum Verdict: Equatable {
    case direct, proxy
}

/// Правила по имени сайта и по IP-адресу. Неизменяемые: при смене настроек собираются заново.
struct RouteRules {
    let mode: RouteMode
    private(set) var suffixes: [String] = []    // «ru»: сам ru и всё, что кончается на .ru
    private(set) var exact: Set<String> = []
    let forcedProxy: Set<String>                 // служебные адреса (проверка DNS), всегда через сервер
    let russia: CIDRSet

    init(mode: RouteMode, directDomains: [String], forcedProxy: Set<String> = [], russia: CIDRSet) {
        self.mode = mode
        self.forcedProxy = forcedProxy
        self.russia = russia
        for raw in directDomains {
            guard let entry = RouteRules.parseEntry(raw) else { continue }
            switch entry {
            case .suffix(let s): suffixes.append(s)
            case .exact(let s): exact.insert(s)
            }
        }
    }

    enum Entry: Equatable {
        case suffix(String), exact(String)
    }

    /// Строка списка «напрямую»: «.ru», «yandex.com», «*.vk.com», «full:host», «domain:host».
    /// geosite:, geoip:, regexp:, keyword: (из NekoBox) не поддерживаются и пропускаются.
    static func parseEntry(_ raw: String) -> Entry? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        for unsupported in ["geosite:", "geoip:", "regexp:", "keyword:", "ext:"] where s.hasPrefix(unsupported) {
            return nil
        }
        var exact = false
        if s.hasPrefix("full:") { exact = true; s.removeFirst(5) }
        if s.hasPrefix("domain:") { s.removeFirst(7) }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, !s.contains(" "), !s.contains("/") else { return nil }
        let ascii = Punycode.toASCII(s)
        return exact ? .exact(ascii) : .suffix(ascii)
    }

    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    func matchesDirect(_ host: String) -> Bool {
        if exact.contains(host) { return true }
        for s in suffixes where host == s || host.hasSuffix("." + s) {
            return true
        }
        return false
    }

    func decide(_ rawHost: String) -> Decision {
        let host = RouteRules.normalizeHost(rawHost)
        if forcedProxy.contains(host) { return .proxy }
        if let ip = IPAddr(host) {
            if ip.isLocal { return .direct }
            if mode == .all { return .proxy }
            return russia.contains(ip) ? .direct : .proxy
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") {
            return .direct
        }
        if mode == .all { return .proxy }
        if matchesDirect(Punycode.toASCII(host)) { return .direct }
        return .lookup
    }
}
