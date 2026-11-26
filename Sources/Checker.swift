import Foundation

/// «Проверить связь и скорость»: через наш прокси узнаём, откуда виден выход в интернет,
/// задержку и скорость скачивания. Всё идёт по тому же пути, что и браузер.
struct CheckReport: Equatable {
    var exitIP: String?
    var countryCode: String?
    var pingMs: Int?
    var mbps: Double?
    var error: String?

    var countryName: String? {
        guard let code = countryCode, !code.isEmpty else { return nil }
        return Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code
    }

    /// Текст для окна с результатом.
    var summary: String {
        if let error { return error }
        var lines: [String] = []
        if let name = countryName { lines.append("Выход в интернет: \(name)" + (exitIP.map { " (\($0))" } ?? "")) }
        if let pingMs { lines.append("Задержка: \(pingMs) мс") }
        if let mbps {
            lines.append(mbps >= 10 ? String(format: "Скорость: %.0f Мбит/с", mbps) : String(format: "Скорость: %.1f Мбит/с", mbps))
        } else {
            lines.append("Скорость измерить не удалось")
        }
        return lines.joined(separator: "\n")
    }

    /// Ответ cloudflare.com/cdn-cgi/trace: строки «ключ=значение».
    static func parseTrace(_ text: String) -> (ip: String?, loc: String?) {
        var ip: String?, loc: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "ip" { ip = kv[1] }
            if kv[0] == "loc" { loc = kv[1] }
        }
        return (ip, loc)
    }
}

enum Checker {
    static func session(proxyPort: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort,
        ]
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }

    static func run(proxyPort: Int) async -> CheckReport {
        let s = session(proxyPort: proxyPort)
        defer { s.invalidateAndCancel() }
        var report = CheckReport()
        do {
            let (data, _) = try await s.data(from: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
            let trace = CheckReport.parseTrace(String(decoding: data, as: UTF8.self))
            report.exitIP = trace.ip
            report.countryCode = trace.loc
        } catch {
            report.error = "Связи через прокси нет.\n\(error.localizedDescription)"
            return report
        }
        // Задержка: лучший из трёх коротких запросов (первый ещё открывает соединение)
        var best: Double?
        for _ in 0..<3 {
            let start = Date()
            if (try? await s.data(from: URL(string: "https://cp.cloudflare.com/generate_204")!)) != nil {
                let ms = Date().timeIntervalSince(start) * 1000
                best = min(best ?? ms, ms)
            }
        }
        report.pingMs = best.map { Int($0.rounded()) }
        report.mbps = await SpeedProbe(session: s).measure(URL(string: "https://speed.cloudflare.com/__down?bytes=50000000")!, seconds: 8)
        return report
    }
}

/// Скачивает файл не дольше заданного времени и считает скорость с первого полученного байта.
final class SpeedProbe: NSObject, URLSessionDataDelegate {
    private let base: URLSession
    private var bytes = 0
    private var firstByte: Date?
    private var lastByte: Date?
    private var continuation: CheckedContinuation<Double?, Never>?
    private let lock = NSLock()

    init(session: URLSession) { base = session }

    func measure(_ url: URL, seconds: Double) async -> Double? {
        let s = URLSession(configuration: base.configuration, delegate: self, delegateQueue: nil)
        defer { s.invalidateAndCancel() }
        return await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
            lock.lock()
            continuation = c
            lock.unlock()
            let task = s.dataTask(with: url)
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 4) { task.cancel() }   // +4 с на подключение
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let started = self.firstByte
                self.lock.unlock()
                if let started, Date().timeIntervalSince(started) >= seconds - 0.5 { task.cancel() }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let now = Date()
        if firstByte == nil { firstByte = now } else { bytes += data.count }
        lastByte = now
        let started = firstByte!
        lock.unlock()
        if now.timeIntervalSince(started) > 8 { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        var result: Double?
        if let first = firstByte, let last = lastByte, last.timeIntervalSince(first) > 0.5, bytes > 0 {
            result = Double(bytes) * 8 / last.timeIntervalSince(first) / 1_000_000
        }
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: result)
    }
}
