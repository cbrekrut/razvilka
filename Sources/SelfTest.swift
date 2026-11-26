import Foundation

/// --selftest: проверки правил и разбора протоколов без сети. Код выхода 0 — всё сошлось.
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok {
            failures += 1
            print("НЕ СОШЛОСЬ (строка \(line)): \(what)")
        }
    }

    static func run() -> Int32 {
        failures = 0
        punycode()
        addresses()
        rules()
        http()
        socks()
        dns()
        config()
        neko()
        misc()
        MenuText.selfTest { ok, what in check(ok, "меню: " + what) }
        settingsForm()
        print(failures == 0 ? "selftest ok" : "selftest: ошибок \(failures)")
        return failures == 0 ? 0 : 1
    }

    static func punycode() {
        check(Punycode.encodeLabel("рф") == "xn--p1ai", "рф")
        check(Punycode.encodeLabel("пример") == "xn--e1afmkfd", "пример")
        check(Punycode.encodeLabel("москва") == "xn--80adxhks", "москва")
        check(Punycode.encodeLabel("bücher") == "xn--bcher-kva", "bücher")
        check(Punycode.toASCII("Пример.РФ") == "xn--e1afmkfd.xn--p1ai", "Пример.РФ")
        check(Punycode.toASCII("Example.com") == "example.com", "латиница не меняется")
    }

    static func addresses() {
        check(IPAddr("1.2.3.4") == .v4(0x0102_0304), "IPv4")
        check(IPAddr("[::1]")?.isLocal == true, "::1 в скобках")
        check(IPAddr("::ffff:10.0.0.1") == .v4(0x0A00_0001), "IPv4 внутри IPv6")
        check(IPAddr("example.com") == nil, "имя — не адрес")
        check(IPAddr("999.1.1.1") == nil, "неверный IPv4")
        for local in ["10.1.2.3", "127.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.31.1", "169.254.1.1", "100.64.0.1", "fe80::1", "fd00::1"] {
            check(IPAddr(local)?.isLocal == true, "\(local) — домашняя сеть")
        }
        for remote in ["172.32.0.1", "8.8.8.8", "100.128.0.1", "2a00:1450::1"] {
            check(IPAddr(remote)?.isLocal == false, "\(remote) — не домашняя сеть")
        }
        let set = CIDRSet(text: "# заметка\n77.88.0.0/18\n5.255.255.0/24\n2a02:6b8::/32\nчушь\n10.0.0.0/33\n")
        check(set.count.v4 == 2 && set.count.v6 == 1, "в наборе 2+1 сети, мусор пропущен")
        check(set.contains(IPAddr("77.88.55.88")!), "77.88.55.88 в 77.88.0.0/18")
        check(!set.contains(IPAddr("77.88.64.1")!), "77.88.64.1 вне /18")
        check(set.contains(IPAddr("5.255.255.70")!), "5.255.255.70")
        check(set.contains(IPAddr("2a02:6b8::1")!), "IPv6 Яндекса")
        check(!set.contains(IPAddr("8.8.8.8")!), "8.8.8.8 не в наборе")
        let merged = CIDRSet(text: "1.0.0.0/24\n1.0.1.0/24\n1.0.0.128/25\n0.0.0.0/0\n")
        check(merged.count.v4 == 1 && merged.contains(IPAddr("200.1.1.1")!), "слияние и /0")
    }

    static func rules() {
        let russia = CIDRSet(text: "77.88.0.0/18\n")
        let r = RouteRules(mode: .rules, directDomains: [".ru", ".su", ".рф", "geosite:private", "yandex.com", "*.vk.com", "full:only.example", "# заметка", ""],
                           forcedProxy: ["dns.google"], russia: russia)
        check(r.decide("sberbank.ru") == .direct, ".ru напрямую")
        check(r.decide("WWW.Gosuslugi.RU.") == .direct, "регистр и точка в конце")
        check(r.decide("xn--e1afmkfd.xn--p1ai") == .direct, ".рф в xn--")
        check(r.decide("пример.рф") == .direct, ".рф кириллицей")
        check(r.decide("music.yandex.com") == .direct, "поддомен yandex.com")
        check(r.decide("vk.com") == .direct, "*.vk.com покрывает и vk.com")
        check(r.decide("only.example") == .direct, "full: точное имя")
        check(r.decide("sub.only.example") == .lookup, "full: не покрывает поддомены")
        check(r.decide("notru.com") == .lookup, "ru в середине не считается")
        check(r.decide("google.com") == .lookup, "прочее — узнать страну")
        check(r.decide("dns.google") == .proxy, "служебный DNS всегда через сервер")
        check(r.decide("localhost") == .direct && r.decide("printer.local") == .direct && r.decide("nas") == .direct, "локальные имена")
        check(r.decide("192.168.31.1") == .direct, "роутер напрямую")
        check(r.decide("77.88.55.88") == .direct, "российский IP напрямую")
        check(r.decide("8.8.8.8") == .proxy, "зарубежный IP через сервер")
        check(r.decide("[2a00:1450::1]") == .proxy, "IPv6 в скобках")
        let all = RouteRules(mode: .all, directDomains: [".ru"], russia: russia)
        check(all.decide("sberbank.ru") == .proxy && all.decide("77.88.55.88") == .proxy, "«всё через прокси»")
        check(all.decide("192.168.31.1") == .direct, "домашняя сеть напрямую даже в «всё через прокси»")
        check(RouteRules.parseEntry("regexp:.*") == nil && RouteRules.parseEntry("domain:ya.ru") == .suffix("ya.ru"), "разбор строк")
    }

    static func http() {
        let connect = HTTPHead.parse(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Connection: keep-alive\r\n\r\n".utf8))
        check(connect?.isConnect == true && connect?.host == "example.com" && connect?.port == 443, "CONNECT")
        let v6 = HTTPHead.parse(Data("CONNECT [2a00:1450::1]:8443 HTTP/1.1\r\n\r\n".utf8))
        check(v6?.host == "2a00:1450::1" && v6?.port == 8443, "CONNECT на IPv6")
        check(HTTPHead.authority("2a00:1450::1", 443) == "[2a00:1450::1]:443", "IPv6 в скобках для сервера")
        let get = HTTPHead.parse(Data("GET http://user:pw@Example.com:8080/a/b?c=1 HTTP/1.1\r\nHost: example.com:8080\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic eA==\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\n".utf8))
        check(get?.host == "Example.com" && get?.port == 8080 && get?.path == "/a/b?c=1", "простой HTTP")
        if let get {
            let text = String(decoding: get.originRequest(), as: UTF8.self)
            check(text == "GET /a/b?c=1 HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\nConnection: close\r\n\r\n", "переписанный запрос: \(text.debugDescription)")
        }
        let noPath = HTTPHead.parse(Data("GET http://example.com?q HTTP/1.0\r\n\r\n".utf8))
        check(noPath?.path == "/?q" && noPath?.port == 80, "путь по умолчанию")
        if let noPath {
            check(String(decoding: noPath.originRequest(), as: UTF8.self).contains("Host: example.com\r\n"), "Host добавлен")
        }
        check(HTTPHead.parse(Data("GET /index.html HTTP/1.1\r\n\r\n".utf8)) == nil, "запрос не к прокси")
        check(HTTPHead.parse(Data("GET https://example.com/ HTTP/1.1\r\n\r\n".utf8)) == nil, "https без CONNECT")
        check(HTTPHead.parse(Data("CONNECT example.com:0 HTTP/1.1\r\n\r\n".utf8)) == nil, "порт 0")
        check(HTTPHead.parse(Data("мусор\r\n\r\n".utf8)) == nil, "мусор")
    }

    static func socks() {
        check(Socks.parseGreeting(Data([5])) == .needMore, "приветствие неполное")
        check(Socks.parseGreeting(Data([5, 2, 0, 2])) == .ok(consumed: 4, methods: [0, 2]), "приветствие")
        check(Socks.parseGreeting(Data([4, 1, 0])) == .invalid, "SOCKS4 не поддерживается")
        var name = Data([5, 1, 0, 3, 11])
        name.append(Data("example.com".utf8))
        name.append(contentsOf: [1, 187])
        check(Socks.parseRequest(name) == .ok(consumed: 18, host: "example.com", port: 443), "запрос по имени")
        check(Socks.parseRequest(name.dropLast()) == .needMore, "запрос неполный")
        check(Socks.parseRequest(Data([5, 1, 0, 1, 8, 8, 4, 4, 0, 53])) == .ok(consumed: 10, host: "8.8.4.4", port: 53), "запрос по IPv4")
        var v6 = Data([5, 1, 0, 4])
        v6.append(contentsOf: [0x2a, 0x00, 0x14, 0x50] + [UInt8](repeating: 0, count: 11) + [1])
        v6.append(contentsOf: [0, 80])
        check(Socks.parseRequest(v6) == .ok(consumed: 22, host: "2a00:1450::1", port: 80), "запрос по IPv6")
        check(Socks.parseRequest(Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])) == .unsupported(consumed: 10), "UDP не поддерживается")
    }

    static func dns() {
        let google = Data(#"{"Status":0,"Answer":[{"name":"music.yandex.net.","type":5,"TTL":600,"data":"a.yandex.net."},{"name":"a.yandex.net.","type":1,"TTL":120,"data":"77.88.55.88"}]}"#.utf8)
        check(Resolver.parse(google) == Resolver.Answer(ips: ["77.88.55.88"], ttl: 120), "ответ DNS с CNAME")
        check(Resolver.parse(Data(#"{"Status":3}"#.utf8)) == Resolver.Answer(ips: [], ttl: 300), "нет такого имени")
        check(Resolver.parse(Data(#"{"Status":2}"#.utf8)) == nil, "сбой DNS")
        check(Resolver.parse(Data("<html>".utf8)) == nil, "не JSON")
        let resolver = Resolver(russia: CIDRSet(text: "77.88.0.0/18"), environment: [:])
        check(resolver.verdict(for: .init(ips: ["8.8.8.8", "77.88.55.88"], ttl: 60)) == .direct, "хоть один российский адрес — напрямую")
        check(resolver.verdict(for: .init(ips: ["8.8.8.8"], ttl: 60)) == .proxy, "зарубежный — через сервер")
        check(resolver.verdict(for: .init(ips: [], ttl: 60)) == .proxy, "без адресов — через сервер")
        check(resolver.hosts == ["dns.google", "cloudflare-dns.com"], "служебные DNS")
    }

    static func config() {
        let partial = try? JSONDecoder().decode(ProxyConfig.self, from: Data(#"{"host":"1.2.3.4","port":8080,"mode":"чепуха","localPort":80}"#.utf8))
        check(partial?.host == "1.2.3.4" && partial?.mode == .rules && partial?.localPort == 2090 && partial?.directDomains == ProxyConfig.defaultDirectDomains,
              "неполный config.json")
        check(partial?.isComplete == true && ProxyConfig().isComplete == false, "isComplete")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("razvilka-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = ProxyConfig()
        c.host = "h"; c.port = 1; c.password = "секрет"
        let url = dir.appendingPathComponent("config.json")
        do {
            try ConfigFile.save(c, to: url)
            check(ConfigFile.load(url) == c, "сохранение и чтение")
            let perms = (try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int
            check(perms == 0o600, "права 600, а не \(String(perms ?? 0, radix: 8))")
        } catch {
            check(false, "сохранение: \(error)")
        }
    }

    static func neko() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("razvilka-neko-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        func put(_ path: String, _ text: String) {
            let url = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        check(NekoImport.find(in: dir) == nil, "NekoBox нет")
        put("profiles/0.json", #"{"type":"vmess","bean":{"addr":"v.example","port":443}}"#)
        put("profiles/2.json", #"{"type":"http","bean":{"addr":"tls.example","port":443,"stream":{"sec":"tls"}}}"#)
        put("profiles/10.json", #"{"type":"http","bean":{"addr":"203.0.113.5","port":8080,"name":"Мой сервер","username":"u","password":"p","stream":{"net":"tcp"}}}"#)
        put("groups/nekobox.json", #"{"active_routing":"Default"}"#)
        put("routes_box/Default", #"{"direct_domain":"geosite:private\n.ru\n.su\n.рф\nregexp:x"}"#)
        let found = NekoImport.find(in: dir)
        check(found == NekoImport.Found(name: "Мой сервер", host: "203.0.113.5", port: 8080, username: "u", password: "p", directDomains: [".ru", ".su", ".рф"]),
              "сервер из NekoBox: \(String(describing: found))")
    }

    static func settingsForm() {
        let model = SettingsModel(config: ProxyConfig(), autostart: true, neko: nil)
        check(model.firstRun && model.build(base: ProxyConfig()) == nil && model.error == "Укажите адрес прокси-сервера", "пустой адрес")
        model.host = " http://203.0.113.5:8080/ "
        model.direct = ".ru\n\n  yandex.com \n"
        let built = model.build(base: ProxyConfig())
        check(built?.host == "203.0.113.5" && built?.port == 8080 && built?.directDomains == [".ru", "yandex.com"] && model.error == nil, "адрес:порт в одном поле")
        model.host = "203.0.113.5"
        model.port = "70000"
        check(model.build(base: ProxyConfig()) == nil && model.error == "Порт — число от 1 до 65535", "неверный порт")
        model.host = "bad host"
        model.port = "80"
        check(model.build(base: ProxyConfig()) == nil, "пробел в адресе")
        var cfg = ProxyConfig()
        cfg.host = "203.0.113.5"; cfg.port = 8080; cfg.enabled = true; cfg.mode = .all
        let found = NekoImport.Found(name: "", host: "198.51.100.1", port: 1080, username: "u", password: "p", directDomains: [".ru"])
        let same = NekoImport.Found(name: "", host: "203.0.113.5", port: 8080, username: "", password: "", directDomains: nil)
        check(SettingsModel(config: cfg, autostart: true, neko: same).neko == nil, "тот же сервер не предлагаем")
        let other = SettingsModel(config: cfg, autostart: true, neko: found)
        check(other.neko == found && !other.firstRun, "другой сервер предлагаем")
        other.importNeko()
        let merged = other.build(base: cfg)
        check(merged?.host == "198.51.100.1" && merged?.username == "u" && merged?.enabled == true && merged?.mode == .all, "перенос сохраняет режим и включённость")
    }

    static func misc() {
        let parsed = SystemProxy.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 2090\nAuthenticated Proxy Enabled: 0\n")
        check(parsed.enabled && parsed.endpoint == SystemProxy.Endpoint(host: "127.0.0.1", port: 2090), "ответ networksetup")
        check(SystemProxy.parse("Enabled: No\nServer: \nPort: 0\n").endpoint == nil, "прокси не задан")
        let trace = CheckReport.parseTrace("fl=1\nip=203.0.113.5\nts=1\nloc=US\n")
        check(trace.ip == "203.0.113.5" && trace.loc == "US", "ответ trace")
        let report = CheckReport(exitIP: "203.0.113.5", countryCode: "US", pingMs: 210, mbps: 5.83, error: nil)
        check(report.summary.contains("210 мс") && report.summary.contains("5.8 Мбит/с") && report.summary.contains("(203.0.113.5)"), "текст проверки: \(report.summary)")
    }
}
