# Split-Tunnel WireGuard

WireGuard split-tunnel для России и стран с похожими блокировками.

**Весь мир через VPN, Россия напрямую.**

```
┌─────────┐                          ┌─────────────┐
│  Zeon   │ ───► github.com         │ VPS abroad  │
│         │    (through WG tunnel)  │  (WireGuard)│
│  client │                          │  NAT        │
│         │ ───► yandex.ru          └─────────────┘
│         │    (direct, bypass VPN)
└─────────┘
```

## Проблема которую решает

В РФ:
- Заблокированы иностранные ресурсы (GitHub, Docker, некоторые CDN)
- При VPN блокируют российские сайты (Сбер, Госуслуги, Yandex)
- Многие SaaS и sandbox отказывают российским IP (sanctions)

Нужно: **разделить трафик умно**.

## Архитектура

- **WireGuard** — лёгкий VPN (не OpenVPN/Shadowsocks)
- **ipset** — хранит 11,000+ российских подсетей
- **iptables + ip rules** — маркирует и маршрутизирует
- **Systemd service** — автозапуск, авто-реконнект

## Работает так

1. Весь трафик идёт в WireGuard (wg0)
2. Endpoint VPS идёт через ISP (фикс рекурсии)
3. Трафик к российским IP (ipset) маркируется (mark 0x1)
4. Маркированный трафик идёт через локальный ISP напрямую
5. Весь остальной (github, google, SaaS) — через VPS

## Быстрый старт

```bash
# Клонируем
# ...
# Сетап скрипт (интерактивный, спросит VPS IP и PublicKey)
# ...
# Детально в SKILL.md
```

## Что устанавливается

- WireGuard + wg-quick (если нет)
- ipset (для IP-баз)
- iptables + iproute2 (маршрутизация)
- systemd сервис `wg-split`
- Скрипты PostUp / PostDown
- База 11,000+ российских IP

## Производительность

- WireGuard ядро-native (fast crypto, ChaCha20)
- ipset O(1) lookups (hash-tables)
- Нет DNS leak (1.1.1.1 через туннель)
- Нет перегрузки (раздельные routing tables)

## Обновления

**Российская IP база** обновляется раз в месяц:
```bash
curl -L https://www.ipdeny.com/ipblocks/data/countries/ru.zone | sudo tee /etc/wireguard/russia.zone
sudo systemctl restart wg-split
```

## Безопасность

- Ключи НЕ в репе
- `chmod 600 /etc/wireguard/*`
- Приватный IP — `192.168.15.3/32`
- VPS endpoint — `51194/udp`
- `PersistentKeepalive = 25` (NAT traversal)

## Troubleshooting

| Симптом | Решение |
|---------|---------|
| Интернет пропал | `sudo /etc/wireguard/safety-stop.sh` |
| WG не стартует | `sudo modprobe wireguard` |
| База не загружена | `curl -L ...ru.zone \| sudo tee ...` |

## Структура скилла

```
split-tunnel/
├── SKILL.md              # Полная документация
└── scripts/
    └── setup.sh          # Интерактивный установщик
```

## Требования

- Linux (Ubuntu/Debian)
- Root доступ (iproute2, iptables)
- VPS с WireGuard server (пример: 2.26.72.38)

## Автор

**Pinman777** — для личного использования в Zeon.

*License: Private (personal use only)*
