import AppKit
import Foundation

// «Развилка»: значок в строке меню, свой маленький прокси на 127.0.0.1 и системные настройки macOS.
// Режимы командной строки нужны сборочному скрипту и тестам.

/// --serve --config <файл> [--port N]: только прокси, без окон и без системных настроек. Для тестов.
func serve(_ args: [String]) -> Int32 {
    var configPath: String?
    var port: UInt16?
    var rest = Array(args.dropFirst(2))
    while !rest.isEmpty {
        let flag = rest.removeFirst()
        switch flag {
        case "--config":
            guard !rest.isEmpty else { return 64 }
            configPath = rest.removeFirst()
        case "--port":
            guard !rest.isEmpty, let p = UInt16(rest.removeFirst()) else { return 64 }
            port = p
        default:
            return 64
        }
    }
    guard let configPath, let config = ConfigFile.load(URL(fileURLWithPath: configPath)) else {
        print("config unreadable")
        return 66
    }
    Log.echo = true
    let core = ProxyCore(config: config, russia: CIDRSet.russia())
    let listenPort = port ?? UInt16(config.localPort)
    core.onProblem = { p in
        let name: String
        switch p {
        case .none: name = "none"
        case .authFailed: name = "auth-failed"
        case .unreachable: name = "unreachable"
        }
        FileHandle.standardOutput.write(Data("problem \(name)\n".utf8))
    }
    core.start(port: listenPort) { error in
        if let error {
            FileHandle.standardOutput.write(Data("failed \(error)\n".utf8))
            exit(69)
        }
        FileHandle.standardOutput.write(Data("listening \(listenPort)\n".utf8))
    }
    // Настройки можно поменять на ходу: SIGHUP перечитывает файл
    signal(SIGHUP, SIG_IGN)
    let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    hup.setEventHandler {
        if let fresh = ConfigFile.load(URL(fileURLWithPath: configPath)) {
            core.apply(fresh)
            FileHandle.standardOutput.write(Data("reloaded\n".utf8))
        }
    }
    hup.resume()
    // SIGUSR1: сколько соединений открыто и сколько байт прошло (проверка, что соединения не висят)
    signal(SIGUSR1, SIG_IGN)
    let usr = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    usr.setEventHandler {
        let s = core.stats.snapshot
        FileHandle.standardOutput.write(Data("stats active=\(s.active) up=\(s.up) down=\(s.down)\n".utf8))
    }
    usr.resume()
    withExtendedLifetime((hup, usr)) { dispatchMain() }
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "--selftest":
    exit(SelfTest.run())
case "--serve":
    exit(serve(arguments))
case "--neko":
    // Что нашлось в NekoBox, без пароля: для проверки переноса
    if let f = NekoImport.find() {
        print("found \(f.host):\(f.port) user=\(f.username.isEmpty ? "-" : "yes") password=\(f.password.isEmpty ? "-" : "yes") direct=\((f.directDomains ?? []).joined(separator: " "))")
    } else {
        print("not found")
    }
    exit(0)
case "--sysproxy-test":
    guard arguments.count >= 3 else { exit(64) }
    let problems = SystemProxy.roundTrip(service: arguments[2], port: 2090)
    print(problems.isEmpty ? "sysproxy ok" : problems.joined(separator: "\n"))
    exit(problems.isEmpty ? 0 : 1)
case "--install-login-item":
    // Сборочный скрипт: автозапуск с перезапуском при сбое (тот же файл, что пишет переключатель в настройках)
    do {
        try LoginItem.setEnabled(true, executable: URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().path)
        print("login item ok")
        exit(0)
    } catch {
        print("login item failed: \(error)")
        exit(1)
    }
case "--glyph-snapshot":
    guard arguments.count >= 3, let png = Glyph.snapshot(), (try? png.write(to: URL(fileURLWithPath: arguments[2]))) != nil else { exit(1) }
    print("glyph ok")
    exit(0)
case "--settings-snapshot":
    // Окно настроек в PNG без экрана: для проверки вёрстки
    guard arguments.count >= 3 else { exit(64) }
    _ = NSApplication.shared
    let png = MainActor.assumeIsolated {
        renderSettingsSnapshot(neko: arguments.contains("--neko"), error: arguments.contains("--error"), filled: arguments.contains("--filled"))
    }
    guard let png, (try? png.write(to: URL(fileURLWithPath: arguments[2]))) != nil else { print("snapshot failed"); exit(1) }
    if let image = NSImage(data: png), let rep = image.representations.first {
        print("settings ok \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
    exit(0)
default:
    MainActor.assumeIsolated { runApp(arguments) }
}
