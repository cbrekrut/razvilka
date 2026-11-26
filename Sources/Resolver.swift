import Foundation

/// Узнаёт, в какой стране сервер сайта: спрашивает адрес у DNS Google (запасной — Cloudflare) по HTTPS
/// через наш же прокси и сверяет со списком российских сетей. Запрос идёт через сервер, поэтому провайдер
/// не может подменить ответ заглушкой. Ответы помнит по времени жизни записи (от минуты до часа).
final class Resolver {
    struct Answer: Equatable {
        var ips: [String]
        var ttl: Int
    }

    private struct Entry {
        var verdict: Verdict
        var expires: Date
    }

    let endpoints: [URL]
    private let russia: CIDRSet
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var waiting: [String: [(Verdict) -> Void]] = [:]
    private var session: URLSession?

    /// Имена служебных серверов DNS: соединения с ними всегда через прокси-сервер, иначе запрос проверял бы сам себя.
    var hosts: Set<String> { Set(endpoints.compactMap { $0.host?.lowercased() }) }

    init(russia: CIDRSet, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.russia = russia
        if let custom = environment["RAZVILKA_DOH"], !custom.isEmpty {
            endpoints = custom.split(separator: ",").compactMap { URL(string: String($0)) }
        } else {
            endpoints = [URL(string: "https://dns.google/resolve")!, URL(string: "https://cloudflare-dns.com/dns-query")!]
        }
    }

    /// Запросы к DNS идут через наш прокси на этом порту.
    func useLocalProxy(port: UInt16) {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(port),
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(port),
        ]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.urlCache = nil
        let fresh = URLSession(configuration: config)
        lock.lock()
        let old = session
        session = fresh
        lock.unlock()
        old?.invalidateAndCancel()
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    func cached(_ host: String) -> Verdict? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[host], entry.expires > Date() else { return nil }
        return entry.verdict
    }

    /// completion вызывается в произвольном потоке ровно один раз.
    func lookup(_ host: String, completion: @escaping (Verdict) -> Void) {
        lock.lock()
        if let entry = cache[host], entry.expires > Date() {
            lock.unlock()
            completion(entry.verdict)
            return
        }
        if waiting[host] != nil {
            waiting[host]!.append(completion)
            lock.unlock()
            return
        }
        waiting[host] = [completion]
        lock.unlock()
        query(host, endpoint: 0)
    }

    private func query(_ host: String, endpoint index: Int) {
        lock.lock()
        let session = self.session
        lock.unlock()
        guard index < endpoints.count, let session,
              var comps = URLComponents(url: endpoints[index], resolvingAgainstBaseURL: false) else {
            finish(host, .proxy, ttl: 30)   // не узнали: через сервер, он откроет любой сайт
            return
        }
        comps.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = comps.url else { finish(host, .proxy, ttl: 30); return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let answer = Resolver.parse(data) else {
                self.query(host, endpoint: index + 1)
                return
            }
            self.finish(host, self.verdict(for: answer), ttl: answer.ttl)
        }.resume()
    }

    func verdict(for answer: Answer) -> Verdict {
        answer.ips.contains { IPAddr($0).map(russia.contains) ?? false } ? .direct : .proxy
    }

    private func finish(_ host: String, _ verdict: Verdict, ttl: Int) {
        lock.lock()
        if cache.count > 5000 {
            let now = Date()
            cache = cache.filter { $0.value.expires > now }
            if cache.count > 5000 { cache.removeAll() }
        }
        cache[host] = Entry(verdict: verdict, expires: Date().addingTimeInterval(TimeInterval(min(max(ttl, 30), 3600))))
        let callbacks = waiting.removeValue(forKey: host) ?? []
        lock.unlock()
        callbacks.forEach { $0(verdict) }
    }

    /// Ответ DNS в JSON (формат Google и Cloudflare). «Нет такого имени» тоже ответ: пустой список.
    static func parse(_ data: Data) -> Answer? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = dict["Status"] as? Int, status == 0 || status == 3 else { return nil }
        let records = dict["Answer"] as? [[String: Any]] ?? []
        let ips = records.filter { ($0["type"] as? Int) == 1 }.compactMap { $0["data"] as? String }
        let ttl = records.compactMap { $0["TTL"] as? Int }.min() ?? 300
        return Answer(ips: ips, ttl: max(ttl, 60))
    }
}
