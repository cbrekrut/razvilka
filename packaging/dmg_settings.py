# Настройки окна установщика для dmgbuild (https://github.com/dmgbuild/dmgbuild).
# Вызывается из build.sh --dmg: dmgbuild -s packaging/dmg_settings.py -D app=... -D background=... -D icon=... "Развилка" файл.dmg
# Положение значков совпадает с фоном из tools/make_art.swift (appSpot, appsSpot).
import os.path

app = defines["app"]  # noqa: F821 — словарь defines подставляет dmgbuild
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Программы": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

icon_locations = {app_name: (170, 140), "Программы": (490, 140)}
window_rect = ((200, 160), (660, 408))  # высота фона 380 + заголовок окна
default_view = "icon-view"
icon_size = 112
text_size = 13
label_pos = "bottom"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
