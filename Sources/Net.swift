import Foundation

/// IP-адрес из текста: IPv4, IPv6 (в том числе в квадратных скобках) и IPv4 внутри IPv6 (::ffff:1.2.3.4).
enum IPAddr: Equatable {
    case v4(UInt32)
    case v6(UInt64, UInt64)

    init?(_ text: String) {
        var s = text
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let zone = s.firstIndex(of: "%") { s = String(s[..<zone]) }
        guard !s.isEmpty else { return nil }
        var a4 = in_addr()
        if inet_pton(AF_INET, s, &a4) == 1 {
            self = .v4(UInt32(bigEndian: a4.s_addr))
            return
        }
        var a6 = in6_addr()
        guard inet_pton(AF_INET6, s, &a6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &a6) { Array($0) }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0..<8 { hi = hi << 8 | UInt64(bytes[i]) }
        for i in 8..<16 { lo = lo << 8 | UInt64(bytes[i]) }
        if hi == 0 && lo >> 32 == 0xFFFF {
            self = .v4(UInt32(truncatingIfNeeded: lo))
            return
        }
        self = .v6(hi, lo)
    }

    /// Домашняя сеть, сам компьютер, служебные адреса: туда всегда напрямую.
    var isLocal: Bool {
        switch self {
        case .v4(let a):
            return a >> 24 == 0          // 0.0.0.0/8
                || a >> 24 == 10         // 10.0.0.0/8
                || a >> 24 == 127        // 127.0.0.0/8
                || a >> 20 == 0xAC1      // 172.16.0.0/12
                || a >> 16 == 0xC0A8     // 192.168.0.0/16
                || a >> 16 == 0xA9FE     // 169.254.0.0/16
                || a >> 22 == 0x191      // 100.64.0.0/10
                || a >> 28 == 0xE        // 224.0.0.0/4
                || a == 0xFFFF_FFFF
        case .v6(let hi, let lo):
            return (hi == 0 && (lo == 0 || lo == 1))   // :: и ::1
                || hi >> 57 == 0x7E                    // fc00::/7
                || hi >> 54 == 0x3FA                   // fe80::/10
                || hi >> 56 == 0xFF                    // ff00::/8
        }
    }
}

/// Набор сетей с быстрым поиском адреса (двоичный поиск по слитым диапазонам).
struct CIDRSet {
    private struct V6: Comparable {
        var hi: UInt64, lo: UInt64
        static func < (a: V6, b: V6) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }
    }

    private var v4: [(start: UInt32, end: UInt32)] = []
    private var v6: [(start: V6, end: V6)] = []

    var count: (v4: Int, v6: Int) { (v4.count, v6.count) }

    init() {}

    /// Строки «адрес/длина», пустые строки и строки с # пропускаются, неверные тоже.
    init(text: String) {
        var r4: [(UInt32, UInt32)] = []
        var r6: [(V6, V6)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "/", maxSplits: 1)
            guard let ip = IPAddr(String(parts[0])) else { continue }
            switch ip {
            case .v4(let a):
                let len = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
                guard (0...32).contains(len) else { continue }
                let mask: UInt32 = len == 0 ? 0 : ~UInt32(0) << UInt32(32 - len)
                r4.append((a & mask, (a & mask) | ~mask))
            case .v6(let hi, let lo):
                let len = parts.count > 1 ? Int(parts[1]) ?? 128 : 128
                guard (0...128).contains(len) else { continue }
                let hiMask: UInt64 = len >= 64 ? ~0 : (len == 0 ? 0 : ~UInt64(0) << UInt64(64 - len))
                let loMask: UInt64 = len <= 64 ? 0 : (len == 128 ? ~0 : ~UInt64(0) << UInt64(128 - len))
                r6.append((V6(hi: hi & hiMask, lo: lo & loMask), V6(hi: (hi & hiMask) | ~hiMask, lo: (lo & loMask) | ~loMask)))
            }
        }
        v4 = CIDRSet.merge(r4)
        v6 = CIDRSet.merge(r6)
    }

    private static func merge<T: Comparable>(_ ranges: [(T, T)]) -> [(start: T, end: T)] {
        var out: [(start: T, end: T)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, r.0 <= last.end {
                if r.1 > last.end { out[out.count - 1].end = r.1 }
            } else {
                out.append((r.0, r.1))
            }
        }
        return out
    }

    private static func find<T: Comparable>(_ x: T, in ranges: [(start: T, end: T)]) -> Bool {
        var lo = 0, hi = ranges.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ranges[mid].start <= x { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best >= 0 && x <= ranges[best].end
    }

    func contains(_ ip: IPAddr) -> Bool {
        switch ip {
        case .v4(let a): return CIDRSet.find(a, in: v4)
        case .v6(let hi, let lo): return CIDRSet.find(V6(hi: hi, lo: lo), in: v6)
        }
    }

    /// Сети России: Resources/ru-cidr.txt в приложении, RAZVILKA_RU_CIDR подменяет файл.
    static func russia() -> CIDRSet {
        if let custom = ProcessInfo.processInfo.environment["RAZVILKA_RU_CIDR"], !custom.isEmpty,
           let text = try? String(contentsOfFile: custom, encoding: .utf8) {
            return CIDRSet(text: text)
        }
        let candidates = [
            Bundle.main.url(forResource: "ru-cidr", withExtension: "txt"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../Resources/ru-cidr.txt").standardizedFileURL,
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return CIDRSet(text: text) }
        }
        Log.write("не найден список российских сетей: российские сайты на не-.ru адресах пойдут через сервер")
        return CIDRSet()
    }
}

/// Перевод доменов с кириллицей в вид, в котором их передают браузеры (пример.рф → xn--e1afmkfd.xn--p1ai).
enum Punycode {
    private static let base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700

    private static func adapt(_ delta: Int, _ numPoints: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= base - tmin
            k += base
        }
        return k + (base - tmin + 1) * delta / (delta + skew)
    }

    private static func digit(_ d: Int) -> Character {
        Character(UnicodeScalar(UInt8(d < 26 ? 97 + d : 22 + d)))   // a–z, затем 0–9
    }

    static func encodeLabel(_ label: String) -> String {
        let input = label.unicodeScalars.map { Int($0.value) }
        guard input.contains(where: { $0 >= 0x80 }) else { return label }
        var output = String(label.unicodeScalars.filter { $0.value < 0x80 }.map(Character.init))
        let b = output.count
        var h = b
        if b > 0 { output.append("-") }
        var n = 128, delta = 0, bias = 72
        while h < input.count {
            let m = input.filter { $0 >= n }.min()!
            delta += (m - n) * (h + 1)
            n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return "xn--" + output
    }

    /// Весь домен: строчными буквами, кириллические части в xn--.
    static func toASCII(_ domain: String) -> String {
        domain.lowercased().split(separator: ".", omittingEmptySubsequences: false)
            .map { encodeLabel(String($0)) }
            .joined(separator: ".")
    }
}
