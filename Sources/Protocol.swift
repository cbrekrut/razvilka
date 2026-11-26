import Foundation

/// Заголовок запроса к прокси: CONNECT host:port (HTTPS и всё прочее) или GET http://host/path (простой HTTP).
struct HTTPHead {
    var method: String
    var target: String
    var version: String
    var headers: [(name: String, value: String)]
    var host: String
    var port: UInt16
    var path: String

    var isConnect: Bool { method == "CONNECT" }

    static func parse(_ data: Data) -> HTTPHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        let method = parts[0].uppercased()
        if method == "CONNECT" {
            guard let (host, port) = parseAuthority(parts[1], defaultPort: 443) else { return nil }
            return HTTPHead(method: method, target: parts[1], version: parts[2], headers: headers, host: host, port: port, path: "")
        }
        // Простой HTTP: адрес целиком в первой строке. https:// без CONNECT не бывает, origin-форма — это запрос не к прокси.
        let target = parts[1]
        guard target.lowercased().hasPrefix("http://") else { return nil }
        let rest = target.dropFirst(7)
        let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        var path = String(rest[cut...])
        if path.isEmpty { path = "/" } else if path.hasPrefix("?") { path = "/" + path }
        guard let (host, port) = parseAuthority(String(rest[..<cut]), defaultPort: 80) else { return nil }
        return HTTPHead(method: method, target: target, version: parts[2], headers: headers, host: host, port: port, path: path)
    }

    /// «host:port», «[::1]:443», «host» (порт по умолчанию). Логин в адресе (user@host) отбрасывается.
    static func parseAuthority(_ raw: String, defaultPort: UInt16) -> (String, UInt16)? {
        var s = Substring(raw)
        if let at = s.lastIndex(of: "@") { s = s[s.index(after: at)...] }
        var host: Substring
        var portText: Substring?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = s[s.index(after: s.startIndex)..<close]
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") { portText = after.dropFirst() } else if !after.isEmpty { return nil }
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            host = s[..<colon]
            portText = s[s.index(after: colon)...]
        } else {
            host = s   // имя без порта или IPv6 без скобок
        }
        guard !host.isEmpty else { return nil }
        var port = defaultPort
        if let portText {
            guard let p = UInt16(portText), p > 0 else { return nil }
            port = p
        }
        return (String(host), port)
    }

    /// Строка «host:port» для CONNECT: IPv6 в квадратных скобках.
    static func authority(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Запрос в том виде, в каком его ждёт сам сайт: короткий путь, без служебных заголовков прокси,
    /// с «Connection: close», чтобы следующий запрос браузер прислал заново через прокси.
    func originRequest() -> Data {
        let hopByHop: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]
        var out = "\(method) \(path) \(version)\r\n"
        var hasHost = false
        for (name, value) in headers where !hopByHop.contains(name.lowercased()) {
            if name.lowercased() == "host" { hasHost = true }
            out += "\(name): \(value)\r\n"
        }
        if !hasHost { out += "Host: \(port == 80 ? host : HTTPHead.authority(host, port))\r\n" }
        out += "Connection: close\r\n\r\n"
        return Data(out.utf8)
    }
}

/// SOCKS5 без пароля, только команда CONNECT.
enum Socks {
    enum Greeting: Equatable {
        case needMore, invalid
        case ok(consumed: Int, methods: [UInt8])
    }

    enum Request: Equatable {
        case needMore, invalid
        case unsupported(consumed: Int)
        case ok(consumed: Int, host: String, port: UInt16)
    }

    static func parseGreeting(_ data: Data) -> Greeting {
        let b = [UInt8](data)
        guard b.count >= 2 else { return .needMore }
        guard b[0] == 5 else { return .invalid }
        let n = Int(b[1])
        guard b.count >= 2 + n else { return .needMore }
        return .ok(consumed: 2 + n, methods: Array(b[2..<(2 + n)]))
    }

    static func parseRequest(_ data: Data) -> Request {
        let b = [UInt8](data)
        guard b.count >= 5 else { return .needMore }
        guard b[0] == 5, b[2] == 0 else { return .invalid }
        let host: String
        let end: Int
        switch b[3] {
        case 1:
            guard b.count >= 10 else { return .needMore }
            host = b[4..<8].map(String.init).joined(separator: ".")
            end = 8
        case 3:
            let len = Int(b[4])
            guard len > 0 else { return .invalid }
            guard b.count >= 5 + len + 2 else { return .needMore }
            guard let name = String(bytes: b[5..<(5 + len)], encoding: .utf8) else { return .invalid }
            host = name
            end = 5 + len
        case 4:
            guard b.count >= 22 else { return .needMore }
            var a6 = in6_addr()
            withUnsafeMutableBytes(of: &a6) { $0.copyBytes(from: b[4..<20]) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &a6, &buf, socklen_t(buf.count)) != nil else { return .invalid }
            host = String(cString: buf)
            end = 20
        default:
            return .invalid
        }
        let port = UInt16(b[end]) << 8 | UInt16(b[end + 1])
        if b[1] != 1 { return .unsupported(consumed: end + 2) }
        guard port > 0 else { return .invalid }
        return .ok(consumed: end + 2, host: host, port: port)
    }

    /// Ответ на запрос: 0 — успех, 1 — общая ошибка, 4 — сайт недоступен, 5 — отказ, 7 — команда не поддерживается.
    static func reply(_ code: UInt8) -> Data {
        Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0])
    }
}
