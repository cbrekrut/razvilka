#!/bin/bash
# Собирает «Развилку», прогоняет проверки и ставит её или делает установщик.
#   ./build.sh               собрать, проверить, поставить в /Applications и запустить
#   ./build.sh --no-install  только собрать и проверить
#   ./build.sh --dmg         собрать, проверить и сделать dist/Razvilka-<версия>.dmg (нужен dmgbuild: pip install dmgbuild)
# Нужны Command Line Tools (swiftc) и python3. Настоящий прокси-сервер в проверках не участвует.
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-install}
case "$MODE" in
    install|--no-install|--dmg) ;;
    *) echo "Неизвестный аргумент: $MODE. Допустимо: без аргументов, --no-install или --dmg" >&2; exit 64 ;;
esac

NAME="Развилка"
APP="build/$NAME.app"
BIN="$APP/Contents/MacOS/Razvilka"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/snapshots build/art

# Картинки: иконка во всех размерах и фон окна установщика
swiftc -O -o build/make_art tools/make_art.swift
build/make_art build/art >/dev/null
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/art/AppIcon.iconset

# Одна программа для Apple Silicon и Intel, macOS 14 и новее
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos14.0" -o "build/Razvilka-$ARCH" Sources/*.swift
done
lipo -create -output "$BIN" build/Razvilka-arm64 build/Razvilka-x86_64
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/ru-cidr.txt "$APP/Contents/Resources/"
codesign --force --sign - "$APP" 2>/dev/null

"$BIN" --selftest

# Прокси целиком: поддельные сайты, поддельный прокси-сервер и поддельный DNS на 127.0.0.1
python3 -I -W ignore tests/test_proxy.py "$BIN"

# Окно настроек и значок в строке меню без экрана: по снимкам проверяется вёрстка
for CASE in "first --neko" "filled --filled" "error --neko --error"; do
    read -r SNAP FLAGS <<< "$CASE"
    OUT=$("$BIN" --settings-snapshot "build/snapshots/settings_$SNAP.png" $FLAGS) || OUT="$OUT (код выхода $?)"
    case "$OUT" in
        "settings ok "*) echo "$SNAP: $OUT" ;;
        *) echo "ПРОВЕРКА НЕ ПРОШЛА: снимок настроек ($SNAP): $OUT" >&2; exit 1 ;;
    esac
done
"$BIN" --glyph-snapshot build/snapshots/glyph.png

echo "build ok ($VERSION)"

if [ "$MODE" = "--dmg" ]; then
    DMGBUILD=${DMGBUILD:-dmgbuild}
    command -v "$DMGBUILD" >/dev/null || { echo "Нет dmgbuild: pip install dmgbuild (или DMGBUILD=путь)" >&2; exit 1; }
    tiffutil -cathidpicheck build/art/dmg-background.png build/art/dmg-background@2x.png -out build/art/dmg-background.tiff 2>/dev/null
    mkdir -p dist
    DMG="dist/Razvilka-$VERSION.dmg"
    rm -f "$DMG"
    "$DMGBUILD" -s packaging/dmg_settings.py -D app="$APP" -D background=build/art/dmg-background.tiff \
        -D icon="$APP/Contents/Resources/AppIcon.icns" "$NAME" "$DMG"
    (cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
    echo "dmg ok: $DMG"
fi

if [ "$MODE" = "install" ]; then
    LABEL=io.github.cbrekrut.razvilka
    DEST="/Applications/$NAME.app"
    # Старую копию останавливаем штатно: она сама уберёт системный прокси, новая включит его снова
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    pkill -TERM -x Razvilka 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Razvilka >/dev/null || break; sleep 0.5; done
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    "$DEST/Contents/MacOS/Razvilka" --install-login-item
    plutil -lint "$HOME/Library/LaunchAgents/$LABEL.plist" >/dev/null
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
    sleep 2
    pgrep -x Razvilka >/dev/null || { echo "Развилка не запустилась" >&2; exit 1; }
    echo "Развилка запущена"
fi
