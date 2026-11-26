"""Собирает Resources/ru-cidr.txt — сети, выданные в России, — из открытой статистики RIPE NCC.

    curl -o delegated.txt https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest
    python3 -I tools/ru_cidr_from_ripe.py delegated.txt Resources/ru-cidr.txt

Формат файла RIPE: registry|cc|type|start|value|date|status|... В строках ipv4 value — число адресов
(не обязательно степень двойки), в строках ipv6 — длина префикса. Берём страну RU, выданные и назначенные блоки.
Это страна регистрации, а не точное местоположение сервера, но для «российский сайт или нет» этого хватает.
"""
import ipaddress
import sys


def main(src, dst):
    v4, v6, stamp = [], [], ""
    with open(src, encoding="ascii", errors="replace") as f:
        for line in f:
            if line.startswith("#"):
                continue
            parts = line.strip().split("|")
            if len(parts) >= 3 and parts[0] == "2" and not stamp:
                d = parts[5]  # строка версии: 2|ripencc|серийный|записей|начало|конец|пояс
                stamp = f"{d[:4]}-{d[4:6]}-{d[6:8]}"
                continue
            if len(parts) < 7 or parts[1] != "RU" or parts[6] not in ("allocated", "assigned"):
                continue
            kind, start, value = parts[2], parts[3], parts[4]
            if kind == "ipv4":
                first = ipaddress.IPv4Address(start)
                last = first + int(value) - 1
                v4.extend(ipaddress.summarize_address_range(first, last))
            elif kind == "ipv6":
                v6.append(ipaddress.IPv6Network(f"{start}/{value}"))
    v4 = list(ipaddress.collapse_addresses(v4))
    v6 = list(ipaddress.collapse_addresses(v6))
    if len(v4) < 1000:
        sys.exit(f"подозрительно мало сетей IPv4: {len(v4)} — файл RIPE неполный?")
    with open(dst, "w") as f:
        f.write(f"# Сети, выданные в России (RU), по статистике RIPE NCC от {stamp}.\n")
        f.write("# Источник: https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest\n")
        for n in v4 + v6:
            f.write(f"{n}\n")
    print(f"ipv4={len(v4)} ipv6={len(v6)} stamp={stamp}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
