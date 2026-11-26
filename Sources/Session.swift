import Foundation
import Network

/// Одно соединение от программы на Mac: разбор запроса, выбор пути, перекачка данных в обе стороны.
/// Всё состояние меняется только в очереди q.
final class Session {
    private enum Stage { case start, socksGreeting, socksRequest, httpHead, routing, piping }
    private enum Reply { case connect, plainHTTP, socks }

    private enum Failure: Error {
        case auth, upstreamDown, upstreamRefused(Int), targetDown, noServer

        var httpBody: String {
            switch self {
            case .auth: return "Прокси-сервер не принял логин или пароль"
            case .upstreamDown: return "Прокси-сервер не отвечает"
            case .upstreamRefused(let code): return "Прокси-сервер отказал (\(code))"
            case .targetDown: return "Сайт не отвечает"
            case .noServer: return "В настройках не указан прокси-сервер"
            }
        }

        var socksCode: UInt8 {
            switch self {
            case .targetDown: return 4
            case .upstreamRefused: return 5
            default: return 1
            }
        }
    }

    private struct Opened {
        var conn: NWConnection
        var leftover: Data
    }

    private let core: ProxyCore
    private let client: NWConnection
    private let q = DispatchQueue(label: "razvilka.session", target: .global(qos: .userInitiated))
    private var stage = Stage.start
    private var reply = Reply.connect
    private var buffer = Data()
    private var conns: [NWConnection] = []
    private var remote: NWConnection?
    private var finished = false
    private var openHalves = 2

    // Гонка «узнать страну сайта» и «заранее подключиться через сервер»
    private var lookupVerdict: Verdict?
    private var speculative: Result<Opened, Failure>?
    private var routed = false

    init(core: ProxyCore, client: NWConnection) {
        self.core = core
        self.client = client
    }

    func start() {
        core.stats.opened()
        conns.append(client)
        client.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        client.start(queue: q)
        q.asyncAfter(deadline: .now() + 30) {
            if self.stage != .piping { self.close() }   // запрос так и не пришёл или сайт не открылся
        }
        readMore()
    }

    // MARK: Разбор запроса

    private func readMore() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if self.finished { return }
            if let data { self.buffer.append(data) }
            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                self.close()
                return
            }
            self.parse()
        }
    }

    private func parse() {
        if stage == .start {
            guard let first = buffer.first else { readMore(); return }
            stage = first == 5 ? .socksGreeting : .httpHead
        }
        switch stage {
        case .socksGreeting:
            switch Socks.parseGreeting(buffer) {
            case .needMore: readMore()
            case .invalid: close()
            case .ok(let consumed, let methods):
                buffer = Data(buffer.dropFirst(consumed))
                guard methods.contains(0) else {
                    sendThenClose(Data([5, 0xFF]))
                    return
                }
                client.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
                stage = .socksRequest
                parse()
            }
        case .socksRequest:
            switch Socks.parseRequest(buffer) {
            case .needMore: readMore()
            case .invalid: close()
            case .unsupported: sendThenClose(Socks.reply(7))
            case .ok(let consumed, let host, let port):
                buffer = Data(buffer.dropFirst(consumed))
                reply = .socks
                route(host: host, port: port)
            }
        case .httpHead:
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 65536 { sendThenClose(httpError(431, "Слишком длинный запрос")) } else { readMore() }
                return
            }
            let rest = Data(buffer[end.upperBound...])
            guard let head = HTTPHead.parse(Data(buffer[..<end.upperBound])) else {
                sendThenClose(httpError(400, "Непонятный запрос"))
                return
            }
            if head.isConnect {
                reply = .connect
                buffer = rest
            } else {
                reply = .plainHTTP
                buffer = head.originRequest() + rest
            }
            route(host: head.host, port: head.port)
        default:
            break
        }
    }

    // MARK: Выбор пути

    private var target = ""

    private func route(host: String, port: UInt16) {
        stage = .routing
        target = HTTPHead.authority(host, port)
        switch core.decide(host) {
        case .direct:
            routed = true
            openDirect(host: host, port: port)
        case .proxy:
            routed = true
            openUpstream(host: host, port: port) { self.finishRouting($0) }
        case .lookup:
            // Пока узнаём страну, уже подключаемся через сервер: для зарубежных сайтов проверка не добавляет задержки
            openUpstream(host: host, port: port) { result in
                self.speculative = result
                self.settleRace(host: host, port: port)
            }
            core.resolver.lookup(RouteRules.normalizeHost(host)) { verdict in
                self.q.async {
                    self.lookupVerdict = verdict
                    self.settleRace(host: host, port: port)
                }
            }
        }
    }

    private func settleRace(host: String, port: UInt16) {
        if routed {
            // Уже пошли напрямую, а соединение через сервер подоспело позже: оно не нужно
            if case .success(let o)? = speculative, o.conn !== remote { o.conn.cancel() }
            return
        }
        guard let verdict = lookupVerdict else { return }
        if verdict == .direct {
            routed = true
            if case .success(let o)? = speculative { o.conn.cancel() }
            openDirect(host: host, port: port)
        } else if let result = speculative {
            routed = true
            finishRouting(result)
        }
    }

    private func openDirect(host: String, port: UInt16) {
        let target = core.testHosts[host.lowercased()] ?? host
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { finishRouting(.failure(.targetDown)); return }
        let conn = NWConnection(host: NWEndpoint.Host(target), port: nwPort, using: ProxyCore.tcpParameters())
        connect(conn) { error in
            self.finishRouting(error == nil ? .success(Opened(conn: conn, leftover: Data())) : .failure(.targetDown))
        }
    }

    private func openUpstream(host: String, port: UInt16, completion: @escaping (Result<Opened, Failure>) -> Void) {
        let cfg = core.currentConfig
        guard cfg.isComplete, let upPort = NWEndpoint.Port(rawValue: UInt16(cfg.port)) else {
            completion(.failure(.noServer))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(cfg.host.trimmingCharacters(in: .whitespaces)), port: upPort,
                                using: ProxyCore.tcpParameters())
        connect(conn) { error in
            if error != nil {
                self.core.report(.unreachable)
                completion(.failure(.upstreamDown))
                return
            }
            let authority = HTTPHead.authority(host, port)
            var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
            if !cfg.username.isEmpty || !cfg.password.isEmpty {
                let token = Data("\(cfg.username):\(cfg.password)".utf8).base64EncodedString()
                request += "Proxy-Authorization: Basic \(token)\r\n"
            }
            request += "\r\n"
            conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            self.readUpstreamHead(conn, Data(), completion: completion)
        }
    }

    private func readUpstreamHead(_ conn: NWConnection, _ acc: Data, completion: @escaping (Result<Opened, Failure>) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
            var acc = acc
            if let data { acc.append(data) }
            if let end = acc.range(of: Data("\r\n\r\n".utf8)) {
                let statusLine = String(decoding: acc[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let parts = statusLine.split(separator: " ")
                let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
                switch code {
                case 200..<300:
                    self.core.report(.none)
                    completion(.success(Opened(conn: conn, leftover: Data(acc[end.upperBound...]))))
                case 407:
                    conn.cancel()
                    self.core.report(.authFailed)
                    completion(.failure(.auth))
                default:
                    conn.cancel()
                    self.core.report(.none)   // сервер жив, просто этот сайт не открыл
                    completion(.failure(.upstreamRefused(code)))
                }
                return
            }
            if error != nil || isComplete || acc.count > 16384 {
                conn.cancel()
                self.core.report(.unreachable)
                completion(.failure(.upstreamDown))
                return
            }
            self.readUpstreamHead(conn, acc, completion: completion)
        }
    }

    /// done вызывается один раз: nil — подключились, иначе ошибка.
    private func connect(_ conn: NWConnection, done: @escaping (NWError?) -> Void) {
        conns.append(conn)
        if finished { conn.cancel(); return }
        var called = false
        conn.stateUpdateHandler = { state in
            guard !called else {
                if case .failed = state { self.close() }
                return
            }
            switch state {
            case .ready:
                called = true
                done(nil)
            case .waiting(let e), .failed(let e):
                called = true
                conn.cancel()
                done(e)
            case .cancelled:
                called = true
                done(NWError.posix(.ECANCELED))
            default:
                break
            }
        }
        conn.start(queue: q)
    }

    private func finishRouting(_ result: Result<Opened, Failure>) {
        guard !finished else {
            if case .success(let o) = result { o.conn.cancel() }
            return
        }
        switch result {
        case .failure(let f):
            if Log.echo { Log.write("fail \(target) \(f)") }   // только в тестовом режиме --serve: адреса сайтов в журнал не пишем
            switch reply {
            case .socks: sendThenClose(Socks.reply(f.socksCode))
            case .connect, .plainHTTP: sendThenClose(httpError(502, f.httpBody))
            }
        case .success(let o):
            remote = o.conn
            switch reply {
            case .connect: client.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            case .socks: client.send(content: Socks.reply(0), completion: .contentProcessed { _ in })
            case .plainHTTP: break
            }
            if !o.leftover.isEmpty {
                core.stats.add(down: o.leftover.count)
                client.send(content: o.leftover, completion: .contentProcessed { _ in })
            }
            if !buffer.isEmpty {
                core.stats.add(up: buffer.count)
                o.conn.send(content: buffer, completion: .contentProcessed { _ in })
                buffer = Data()
            }
            stage = .piping
            pump(from: client, to: o.conn, up: true)
            pump(from: o.conn, to: client, up: false)
        }
    }

    // MARK: Перекачка

    private func pump(from: NWConnection, to: NWConnection, up: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            if self.finished { return }
            if let data, !data.isEmpty {
                if up { self.core.stats.add(up: data.count) } else { self.core.stats.add(down: data.count) }
                to.send(content: data, completion: .contentProcessed { sendError in
                    if self.finished { return }
                    if sendError != nil { self.close(); return }
                    if isComplete { self.halfClose(to) }
                    else if error != nil { self.close() }
                    else { self.pump(from: from, to: to, up: up) }
                })
                return
            }
            if isComplete { self.halfClose(to); return }
            if error != nil { self.close(); return }
            self.pump(from: from, to: to, up: up)
        }
    }

    /// Одна сторона закончила: передаём «конец данных» другой, после обеих — закрываем всё.
    private func halfClose(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            self.openHalves -= 1
            if self.openHalves <= 0 { self.close() }
        })
    }

    private func httpError(_ code: Int, _ text: String) -> Data {
        let body = Data(text.utf8)
        let reason = code == 400 ? "Bad Request" : code == 431 ? "Request Header Fields Too Large" : "Bad Gateway"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private func sendThenClose(_ data: Data) {
        client.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            self.close()
        })
    }

    private func close() {
        guard !finished else { return }
        finished = true
        for c in conns { c.cancel() }
        conns.removeAll()
        remote = nil
        core.stats.closed()
    }
}
