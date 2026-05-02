#!/usr/bin/env bash
# =============================================================================
# Setup: Split-Tunnel WireGuard (Russia Bypass)
# =============================================================================
# Весь трафик через VPS, КРОМЕ российских IP.
# Зарубежные сайты → VPN, российские → ISP напрямую.
# =============================================================================

set -euo pipefail

VPS_ENDPOINT="${VPS_ENDPOINT:-}"
VPS_WG_PUBLIC="${VPS_WG_PUBLIC:-}"
VPS_PORT="${VPS_PORT:-51820}"
CLIENT_IP="${CLIENT_IP:-192.168.15.3/32}"
WG_DIR="/etc/wireguard"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- CHECK ROOT ----
if [ "$EUID" -ne 0 ]; then
    log_error "Run as root or with sudo"
    exit 1
fi

# ---- CHECK DEPS ----
log_info "Checking dependencies..."
for pkg in wireguard wireguard-tools ipset iptables iproute2 curl; do
    if ! dpkg -l | grep -q "^ii  ${pkg} " 2>/dev/null; then
        log_warn "Installing ${pkg}..."
        apt-get update >/dev/null
        apt-get install -y ${pkg}
    fi
done

# ---- GET INPUTS ----
log_info "This script sets up WireGuard split-tunnel for Russia."
log_warn "You need: VPS with WireGuard server, its PublicKey, and endpoint IP."

# Read endpoint (hidden if exists)
if [ -z "${VPS_ENDPOINT}" ]; then
    read -rp "Enter VPS IP/hostname [e.g. 203.0.113.1]: " raw_ep
    VPS_ENDPOINT="${raw_ep}"
fi

if [ -z "${VPS_ENDPOINT}" ] || [ "${VPS_ENDPOINT}" = "PLACEHOLDER" ]; then
    log_error "VPS endpoint required. Set VPS_ENDPOINT env or enter when prompted."
    exit 1
fi

if [ -z "${VPS_WG_PUBLIC}" ] || [ "${VPS_WG_PUBLIC}" = "PLACEHOLDER" ]; then
    read -rp "Enter VPS WireGuard PublicKey: " VPS_WG_PUBLIC
    if [ -z "${VPS_WG_PUBLIC}" ] || [ "${VPS_WG_PUBLIC}" = "PLACEHOLDER" ]; then
        log_error "VPS PublicKey required."
        exit 1
    fi
fi

# ---- GENERATE KEYS ----
log_info "Generating WireGuard keys..."
mkdir -p ${WG_DIR}
chmod 700 ${WG_DIR}

wg genkey | tee ${WG_DIR}/privatekey | wg pubkey > ${WG_DIR}/publickey
chmod 600 ${WG_DIR}/privatekey
CLIENT_PRIV=$(cat ${WG_DIR}/privatekey)
CLIENT_PUB=$(cat ${WG_DIR}/publickey)

log_info "Client PublicKey (add to VPS): ${CLIENT_PUB}"

# ---- CREATE CONFIG ----
log_info "Creating WireGuard config..."
cat > ${WG_DIR}/wg0.conf <>EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420
Table = off

[Peer]
PublicKey = ${VPS_WG_PUBLIC}
Endpoint = ${VPS_ENDPOINT}:${VPS_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 ${WG_DIR}/wg0.conf

log_info "Config saved to ${WG_DIR}/wg0.conf"

# ---- DOWNLOAD RUSSIAN IP LIST ----
log_info "Downloading Russian IP blocks..."
if curl -sL --max-time 30 "https://www.ipdeny.com/ipblocks/data/countries/ru.zone" > ${WG_DIR}/russia.zone; then
    COUNT=$(wc -l < ${WG_DIR}/russia.zone)
    log_info "Loaded ${COUNT} Russian IP blocks"
else
    log_warn "Failed to download. Using fallback list."
    cat > ${WG_DIR}/russia.zone <<'FALLBACK'
# Fallback Russian networks (manual)
5.255.192.0/18
77.88.0.0/18
87.250.224.0/19
93.158.128.0/18
95.108.128.0/17
141.8.128.0/18
178.154.128.0/17
213.180.192.0/19
79.137.174.0/24
87.240.128.0/18
178.248.232.0/21
FALLBACK
fi
chmod 644 ${WG_DIR}/russia.zone

# ---- CREATE SCRIPTS ----
cat > ${WG_DIR}/split-up.sh <>'POSTUP'
#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
VPS_IP="${VPS_ENDPOINT}"
LOCAL_IF=$(ip route | grep default | head -1 | awk '{print $5}')
RU_TABLE=100

# Route endpoint via ISP (break recursion)
ip route add \${VPS_IP}/32 dev \${LOCAL_IF} metric 1 2>/dev/null || true

# RU routing table
grep -q "^\${RU_TABLE}\\s" /etc/iproute2/rt_tables || echo "\${RU_TABLE} russia" >> /etc/iproute2/rt_tables
GW=$(ip route | grep default | grep \${LOCAL_IF} | head -1 | awk '{print $3}')
ip route add default via \${GW} dev \${LOCAL_IF} table russia 2>/dev/null || true

# Create and populate ipset
ipset create ru hash:net maxelem 262144 2>/dev/null || ipset flush ru 2>/dev/null || true
if ipset list ru >/dev/null 2>&1; then :
  ipset flush ru
  while IFS= read -r net; do
      ipset add ru \${net} 2>/dev/null || true
  done < /etc/wireguard/russia.zone
fi

# Mark Russian traffic
iptables -t mangle -A OUTPUT -m set --match-set ru dst -j MARK --set-mark 0x1 2>/dev/null || true
ip rule add priority 500 fwmark 0x1 lookup russia 2>/dev/null || true

# Split default (recursive fix)
ip route add 0.0.0.0/1 dev \${WG_IF} 2>/dev/null || true
ip route add 128.0.0.0/1 dev \${WG_IF} 2>/dev/null || true

logger -t wg-split "PostUp: WG \${WG_IF} up, Russian bypass active"
echo "PostUp complete"
POSTUP
chmod +x ${WG_DIR}/split-up.sh

cat > ${WG_DIR}/split-down.sh <>PREDOWN
#!/bin/bash
ip route flush dev wg0 2>/dev/null || true
ip route del ${VPS_ENDPOINT}/32 dev $(ip route | grep default | head -1 | awk '{print $5}') 2>/dev/null || true
ipset flush ru 2>/dev/null || true
for p in $(ip rule show | grep -E "lookup russia|fwmark" | awk -F: '{print $1}'); do
    ip rule del pref \${p} 2>/dev/null || true
done
ip route flush table 100 2>/dev/null || true
echo "PostDown complete"
PREDOWN
chmod +x ${WG_DIR}/split-down.sh

# ---- SAFETY STOP ----
cat > ${WG_DIR}/safety-stop.sh <>SAFETY
#!/bin/bash
wg-quick down wg0 2>/dev/null || true
ip route flush dev wg0 2>/dev/null || true
ipset flush ru 2>/dev/null || true
for p in \$(ip rule show | grep -E "lookup russia|fwmark" | awk -F: '{print \$1}'); do
    ip rule del pref \$p 2>/dev/null || true
done
ip route flush table 100 2>/dev/null || true
echo "Emergency stop executed: \$(date)"
SAFETY
chmod +x ${WG_DIR}/safety-stop.sh

# ---- SYSTEMD SERVICE ----
cat > /etc/systemd/system/wg-split.service <>UNIT
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
UNIT

systemctl daemon-reload
systemctl enable wg-split.service

# ---- FINISH ----
log_info "Setup complete!"
echo ""
echo "==== NEXT STEPS ===="
echo "1. Add this PublicKey to VPS WireGuard peers:"
echo "   ${GREEN}${CLIENT_PUB}${NC}"
echo ""
echo "2. On VPS, run:"
echo "   wg set wg0 peer '${CLIENT_PUB}' allowed-ips ${CLIENT_IP}"
echo ""
echo "3. Start tunnel:"
echo "   systemctl start wg-split"
echo ""
echo "4. Verify:"
echo "   curl ipinfo.io    # should show VPS IP"
echo "   curl ipinfo.io    # yandex.ru should show your ISP IP"
echo ""
echo "5. Emergency stop (if internet breaks):"
echo "   /etc/wireguard/safety-stop.sh"
echo ""
echo "6. Update Russian IPs monthly:"
echo "   curl -L https://www.ipdeny.com/ipblocks/data/countries/ru.zone | sudo tee /etc/wireguard/russia.zone > /dev/null"
