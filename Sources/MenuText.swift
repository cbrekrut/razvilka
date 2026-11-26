import Foundation

/// Что показать в меню: собирается из состояния, без AppKit, поэтому проверяется в --selftest.
struct MenuState: Equatable {
    var configured = false
    var on = false
    var busy: Bool? = nil            // true — включаю, false — выключаю, nil — ничего не делаю
    var server = ""
    var problem = UpstreamProblem.none
    var hijackedBy: String? = nil    // системный прокси сейчас указывает на чужой адрес
    var listenError: String? = nil
    var nekoBlocking = false         // при запуске NekoBox работал, сами не включились
    var mode = RouteMode.rules
    var downBytesPerSec = 0.0
    var upBytesPerSec = 0.0
}

enum MenuText {
    enum Tone { case good, off, warning }

    static func status(_ s: MenuState) -> (text: String, tone: Tone) {
        if let busy = s.busy { return (busy ? "Включаю…" : "Выключаю…", .off) }
        if !s.configured { return ("Сервер не настроен", .warning) }
        if s.on {
            let bad = s.problem != .none || s.hijackedBy != nil || s.listenError != nil
            return ("Включено · через \(s.server)", bad ? .warning : .good)
        }
        if s.nekoBlocking { return ("Выключено · работает NekoBox", .off) }
        return ("Выключено", .off)
    }

    static func problem(_ s: MenuState) -> String? {
        if let e = s.listenError { return e }
        switch s.problem {
        case .authFailed: return "Сервер не принял логин или пароль"
        case .unreachable: return "Сервер не отвечает"
        case .none: break
        }
        if s.on, s.hijackedBy != nil { return "Настройки прокси изменила другая программа" }
        return nil
    }

    static func speed(_ s: MenuState) -> String? {
        guard s.on, s.busy == nil else { return nil }
        return "↓ \(bits(s.downBytesPerSec))   ↑ \(bits(s.upBytesPerSec))"
    }

    static func toggle(_ s: MenuState) -> String {
        s.on ? "Выключить" : "Включить"
    }

    /// Байты в секунду → «3,2 Мбит/с», «120 Кбит/с».
    static func bits(_ bytesPerSec: Double) -> String {
        let bps = max(0, bytesPerSec) * 8
        let ru = Locale(identifier: "ru_RU")
        if bps >= 10_000_000 { return String(format: "%.0f Мбит/с", locale: ru, bps / 1_000_000) }
        if bps >= 1_000_000 { return String(format: "%.1f Мбит/с", locale: ru, bps / 1_000_000) }
        return String(format: "%.0f Кбит/с", locale: ru, bps / 1000)
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        var s = MenuState(configured: true, on: true, server: "203.0.113.5")
        check(status(s) == ("Включено · через 203.0.113.5", .good), "включено")
        check(toggle(s) == "Выключить" && problem(s) == nil, "кнопка и нет беды")
        s.downBytesPerSec = 400_000
        s.upBytesPerSec = 15_000
        check(speed(s) == "↓ 3,2 Мбит/с   ↑ 120 Кбит/с", "скорость: \(speed(s) ?? "nil")")
        s.problem = .authFailed
        check(status(s).tone == .warning && problem(s) == "Сервер не принял логин или пароль", "неверный пароль")
        s.problem = .none
        s.hijackedBy = "127.0.0.1:2080"
        check(problem(s) == "Настройки прокси изменила другая программа", "перехват")
        s.on = false
        check(status(s) == ("Выключено", .off) && speed(s) == nil && problem(s) == nil, "выключено")
        s.nekoBlocking = true
        check(status(s).text == "Выключено · работает NekoBox", "NekoBox мешает")
        s.busy = true
        check(status(s).text == "Включаю…", "включаю")
        check(status(MenuState()).text == "Сервер не настроен", "не настроен")
        check(bits(2_000_000) == "16 Мбит/с" && bits(0) == "0 Кбит/с", "крайние скорости")
    }
}
