---
name: split-tunnel
category: devops
description: |
  WireGuard split-tunnel: весь трафик через VPS, КРОМЕ российских IP (Yandex, VK, банки, госуслуги).
  Зарубежные сайты через VPN, российские через ISP без блокировки.
triggers:
  - "split tunnel"
  - "обход блокировок"
  - "vpn россия"
  - "rossiianskii traffic bypass"
  - "vse krome ru"
  - "заблокированные сайты"
  - "sanctions bypass"
prerequisites:
  - wireguard
  - ipset
  - iptables
  - systemd
  - VPS with WireGuard server
---

# Split-Tunnel WireGuard для России

## Проблема

В РФ блокируют:
- Иностранные ресурсы (sanctions)
- При подключенном VPN блокируют российские сайты

Нужно: **всё кроме российского** → VPS, **российское** → напрямую.

## Архитектура

```
┌─────────┐
│  Zeon   │
│(client) │
│192.168. │
│  15.3   │
└────┬────┘
     │ WG tunnel (порт 51194 UDP)
     │ Трафик: foreign sites (github, google, etc)
     └── Russian sites (yandex, vk, sber, gosuslugi) ──► ISP напрямую

┌────────────────────────────────────┐
│  VPS 2.26.72.38 (WireGuard server) │
│  wg0: 192.168.15.1/24              │
│  MASQUERADE + NAT                  │
└────────────────────────────────────┘
```

## Быстрый старт на Zeon

### 1. Установка WireGuard
```bash
sudo apt-get install -y wireguard wireguard-tools ipset iptables iproute2
```

### 2. Генерация ключей
```bash
sudo bash -c 'cd /etc/wireguard && wg genkey | tee privatekey | wg pubkey > publickey && chmod 600 privatekey'
ZPUB=$(sudo cat /etc/wireguard/publickey)
ZPRIV=$(sudo cat /etc/wireguard/privatekey)
```

### 3. Добавить на VPS peer
```bash
# SSH на VPS root@2.26.72.38
wg set wg0 peer "${ZPUB}" allowed-ips 192.168.15.3/32
wg show
```

### 4. Создать клиент конфиг
```bash
sudo bash -c "cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
PrivateKey = ${ZPRIV}
Address = 192.168.15.3/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420
Table = off        # важно: не ловить рекурсию

[Peer]
PublicKey = cO+FLS17zBjj+CGgbnRQxPlkVGTLdFx/HsBUgoPqnzU=
Endpoint = 2.26.72.38:51194
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf"
```

### 5. split-up скрипт (пост-запуск)
Создать `/etc/wireguard/split-up.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
VPS_IP="2.26.72.38"
LOCAL_IF="enp6s0"
RU_TABLE=100

# Endpoint route via ISP (recursion fix)
ip route add ${VPS_IP}/32 dev ${LOCAL_IF} metric 1 || true

# Create RU routing table
echo "${RU_TABLE} russia" >> /etc/iproute2/rt_tables || true

gw=$(ip route | grep default | grep ${LOCAL_IF} | awk '{print $3}')
ip route add default via ${gw} dev ${LOCAL_IF} table russia || true

# Create ipset and load 11000+ Russian networks
ipset create ru hash:net maxelem 262144 2>/dev/null || ipset flush ru || true

# Load from /etc/wireguard/russia.zone (download once: ipdeny.ru.zone)
if [ -f /etc/wireguard/russia.zone ]; then
    while IFS= read -r net; do
        ipset add ru ${net} 2>/dev/null || true
    done < /etc/wireguard/russia.zone
fi

# Mark and route
iptables -t mangle -A OUTPUT -m set --match-set ru dst -j MARK --set-mark 0x1 || true
ip rule add priority 500 fwmark 0x1 lookup russia || true

# Split default (0/1 + 128/1 avoids AllowedIPs recursion)
ip route add 0.0.0.0/1 dev ${WG_IF} || true
ip route add 128.0.0.0/1 dev ${WG_IF} || true

echo "PostUp complete"
```

```bash
chmod +x /etc/wireguard/split-up.sh
```

### 6. split-down (очистка)
Создать `/etc/wireguard/split-down.sh`:
```bash
#!/bin/bash
ip route flush dev wg0 || true
ipset flush ru || true
for p in $(ip rule show | grep -E "lookup russia|fwmark" | awk -F: '{print $1}'); do
    ip rule del pref $p || true
done
ip route flush table 100 || true
ip route del ${VPS_IP}/32 dev enp6s0 || true
```

```bash
chmod +x /etc/wireguard/split-down.sh
```

### 7. Systemd сервис
Создать `/etc/systemd/system/wg-split.service`:
```ini
[Unit]
Description=WireGuard Split-Tunnel (Russia bypass)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'wg-quick up wg0 && /etc/wireguard/split-up.sh'
ExecStop=/bin/bash -c '/etc/wireguard/split-down.sh && wg-quick down wg0'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wg-split
```

### 8. Скачать Russian IP базу (однократно)
```bash
curl -L https://www.ipdeny.com/ipblocks/data/countries/ru.zone | sudo tee /etc/wireguard/russia.zone > /dev/null
echo "Loaded $(wc -l < /etc/wireguard/russia.zone) networks"
```

### 9. Если всё сломалось — emergency stop
```bash
sudo wg-quick down wg0 2>/dev/null || true
sudo ip route flush dev wg0 2>/dev/null || true
# Интернет сразу вернётся
```

## Проверка

```bash
# Туннель активен?
sudo wg show

# Куда идёт трафик?
curl -s ipinfo.io          # должен показать IP VPS (2.26.72.38)
curl -s yandex.ru          # должен показать твой ISP IP

# Проверить DNS
nslookup google.com        # через VPS
nslookup yandex.ru         # через ISP

# Проверить маршруты
ip rule show
ipset list ru | head -5
```

## Обновление Russian IP

Раз в месяц обновлять базу:
```bash
curl -L https://www.ipdeny.com/ipblocks/data/countries/ru.zone | sudo tee /etc/wireguard/russia.zone > /dev/null
sudo systemctl restart wg-split
```

## Добавить кастомные сети

```bash
# Ручное добавление (пример: Сбер)
echo "194.54.16.0/20" | sudo tee -a /etc/wireguard/russia.zone
sudo systemctl restart wg-split
```

## Безопасность

- Приватный ключ Zeon: `chmod 600 /etc/wireguard/privatekey`
- В репу НЕ добавлять ключи
- В репу НЕ добавлять IP VPS
- В репу добавляем только TEMPLATES с `PLACEHOLDER` и скрипты настройки

## Troubleshooting

| Проблема | Решение |
|----------|---------|
| Интернет пропал | `sudo wg-quick down wg0` |
| WG не стартует | `sudo modprobe wireguard` |
| ipset не создаётся | `sudo apt install ipset` |
| DNS не работает | `sudo resolvectl flush-caches` |
| Рекурсия пакетов | Проверь Endpoint route через ISP |

## Удаление

```bash
sudo systemctl stop wg-split
sudo systemctl disable wg-split
sudo wg-quick down wg0
sudo rm -rf /etc/wireguard/
sudo systemctl daemon-reload
```

## Зависимости

- wireguard
- wireguard-tools
- ipset
- iptables
- iproute2
- systemd
- curl (для скачивания ru.zone)
