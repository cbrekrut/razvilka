import Foundation
import Network

/// Беда с прокси-сервером, которую стоит показать в меню.
enum UpstreamProblem: Equatable {
    case none
    case authFailed            // сервер ответил 407: логин или пароль не подходят
    case unreachable           // до сервера не достучаться
}

/// Счётчики трафика для строки скорости в меню.
final class Stats {
    private let lock = NSLock()
    private var up: UInt64 = 0
    private var down: UInt64 = 0
    private var active = 0

    func add(up n: Int) { lock.lock(); up &+= UInt64(n); lock.unlock() }
    func add(down n: Int) { lock.lock(); down &+= UInt64(n); lock.unlock() }
    func opened() { lock.lock(); active += 1; lock.unlock() }
    func closed() { lock.lock(); active -= 1; lock.unlock() }

    var snapshot: (up: UInt64, down: UInt64, active: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (up, down, active)
    }
}

/// Сам прокси: слушает 127.0.0.1:порт, принимает HTTP и SOCKS5, решает, куда вести соединение.
final class ProxyCore {
    let stats = Stats()
    let resolver: Resolver
    let russia: CIDRSet
    /// Только для проверок: «имя=адрес» вместо системного DNS при прямом соединении (RAZVILKA_TEST_HOSTS).
    let testHosts: [String: String]
    /// Вызывается в произвольном потоке, только когда беда меняется.
    var onProblem: ((UpstreamProblem) -> Void)?

    private let lock = NSLock()
    private var config: ProxyConfig
    private var rules: RouteRules
    private var problem = UpstreamProblem.none
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "razvilka.listener")

    init(config: ProxyConfig, russia: CIDRSet, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.config = config
        self.russia = russia
        resolver = Resolver(russia: russia, environment: environment)
        rules = RouteRules(mode: config.mode, directDomains: config.directDomains, forcedProxy: resolver.hosts, russia: russia)
        var hosts: [String: String] = [:]
        for pair in (environment["RAZVILKA_TEST_HOSTS"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { hosts[String(kv[0]).lowercased()] = String(kv[1]) }
        }
        testHosts = hosts
    }

    var currentConfig: ProxyConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    var currentProblem: UpstreamProblem {
        lock.lock()
        defer { lock.unlock() }
        return problem
    }

    /// Новые настройки действуют для новых соединений, открытые не трогаются.
    func apply(_ new: ProxyConfig) {
        lock.lock()
        let old = config
        config = new
        rules = RouteRules(mode: new.mode, directDomains: new.directDomains, forcedProxy: resolver.hosts, russia: russia)
        lock.unlock()
        if !new.sameUpstream(as: old) {
            report(.none)   // старая беда относилась к прежнему серверу
        }
        if !new.sameUpstream(as: old) || new.directDomains != old.directDomains { resolver.clearCache() }
    }

    func decide(_ host: String) -> Decision {
        lock.lock()
        let r = rules
        lock.unlock()
        let d = r.decide(host)
        guard d == .lookup else { return d }
        switch resolver.cached(RouteRules.normalizeHost(host)) {
        case .direct?: return .direct
        case .proxy?: return .proxy
        case nil: return .lookup
        }
    }

    func report(_ p: UpstreamProblem) {
        lock.lock()
        let changed = p != problem
        problem = p
        lock.unlock()
        guard changed else { return }
        switch p {
        case .none: Log.write("сервер снова отвечает")
        case .authFailed: Log.write("сервер не принял логин или пароль (407)")
        case .unreachable: Log.write("сервер не отвечает")
        }
        onProblem?(p)
    }

    /// completion: nil — слушаем; ошибка — порт занят или недоступен.
    func start(port: UInt16, completion: @escaping (Error?) -> Void) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(NWError.posix(.EINVAL))
            return
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            completion(error)
            return
        }
        var reported = false
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !reported { reported = true; completion(nil) }
            case .failed(let e), .waiting(let e):
                Log.write("порт \(port) не открылся: \(e)")
                l.cancel()
                if !reported { reported = true; completion(e) }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            Session(core: self, client: conn).start()
        }
        lock.lock()
        listener = l
        lock.unlock()
        resolver.useLocalProxy(port: port)
        l.start(queue: listenerQueue)
    }

    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
    }

    /// Соединения наружу: без системного прокси (иначе шли бы сами в себя), с таймаутом подключения.
    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let params = NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        return params
    }
}
