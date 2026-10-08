#!/usr/bin/env bash

set -u

APP_DIR="/opt/zapret-gateway"
DATA_DIR="/data"
WG_DIR="${DATA_DIR}/wg"

log() { echo "[zapret-vpn-gateway] $*"; }

IPT="$(command -v iptables-legacy || command -v iptables || true)"

mkdir -p "${WG_DIR}" /run

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || log "WARN: не удалось включить net.ipv4.ip_forward (нужен NET_ADMIN)"
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true

IFACE="${APP_ZAPRET_VPN_IFACE:-eth0}"
GATEWAY_IP="$(ip -4 -o addr show dev "${IFACE}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
if [ -z "${GATEWAY_IP}" ]; then
    GATEWAY_IP="$(ip -4 -o addr show 2>/dev/null | grep -v ' lo ' | awk '{print $4}' | cut -d/ -f1 | head -n1)"
fi
if [ -z "${GATEWAY_IP}" ]; then
    GATEWAY_IP="0.0.0.0"
    log "WARN: не удалось определить IP контейнера в umbrel_main_network"
fi
echo "${GATEWAY_IP}" > "${DATA_DIR}/gateway_ip"
log "IP шлюза в umbrel_main_network: ${GATEWAY_IP}"

if [ -n "${IPT}" ]; then
    "${IPT}" -t nat -C POSTROUTING -o "${IFACE}" -j MASQUERADE 2>/dev/null || "${IPT}" -t nat -A POSTROUTING -o "${IFACE}" -j MASQUERADE
    "${IPT}" -t nat -C POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || "${IPT}" -t nat -A POSTROUTING -o wg0 -j MASQUERADE
fi

WG_PORT="${APP_ZAPRET_VPN_WG_PORT:-51820}"
WG_SUBNET="${APP_ZAPRET_VPN_WG_SUBNET:-10.11.12.0/24}"
WG_ADDR="$(echo "${WG_SUBNET}" | sed -E 's#(\.0)?/([0-9]+)$#.1/\2#')"

if [ ! -f "${WG_DIR}/server.key" ]; then
    wg genkey > "${WG_DIR}/server.key"
    chmod 600 "${WG_DIR}/server.key"
fi
SERVER_KEY="$(cat "${WG_DIR}/server.key")"
SERVER_PUB="$(wg pubkey < "${WG_DIR}/server.key")"
echo "${SERVER_PUB}" > "${WG_DIR}/server.pub"

{
    echo "[Interface]"
    echo "PrivateKey = ${SERVER_KEY}"
    echo "ListenPort = ${WG_PORT}"
    echo "Address = ${WG_ADDR}"
    echo "SaveConfig = false"
    echo ""
    if [ -f "${WG_DIR}/peers.json" ]; then
        jq -r 'to_entries[] | "[Peer]\nPublicKey = \(.value.pubkey)\nAllowedIPs = \(.value.address)\n"' "${WG_DIR}/peers.json" 2>/dev/null
    fi
} > "${WG_DIR}/wg0.conf"

WG_OUT="$(wg-quick up wg0 2>&1)" && WG_RC=0 || WG_RC=$?
echo "${WG_OUT}" | sed 's/^/[wireguard] /'
if [ "${WG_RC}" -ne 0 ]; then
    log "WARN: wg-quick up wg0 не удался (модуль wireguard в ядре?)"
fi

cleanup() {
    log "Завершение работы: восстанавливаю маршруты контейнеров..."
    "${APP_DIR}/route-manager.sh" cleanup >/dev/null 2>&1 || true
    "${APP_DIR}/zapret.sh" stop >/dev/null 2>&1 || true
    wg-quick down wg0 >/dev/null 2>&1 || true
    exit 0
}
trap cleanup TERM INT

ZAPRET_MODE="${APP_ZAPRET_VPN_MODE:-nfqws}"
if [ "${ZAPRET_MODE}" != "none" ]; then
    "${APP_DIR}/zapret.sh" start || log "WARN: zapret не запустился"
fi

"${APP_DIR}/route-manager.sh" watch &
RM_PID=$!

python3 "${APP_DIR}/server.py" &
WEB_PID=$!

log "Готово. Панель управления: http://umbrel.local:8095"
log "Смотрите docker logs этого контейнера для QR-кода WireGuard."

while true; do
    sleep 30
    if ! kill -0 "${WEB_PID}" 2>/dev/null; then
        log "Перезапускаю веб-панель..."
        python3 "${APP_DIR}/server.py" &
        WEB_PID=$!
    fi
    if ! kill -0 "${RM_PID}" 2>/dev/null; then
        log "Перезапускаю демон маршрутизации..."
        "${APP_DIR}/route-manager.sh" watch &
        RM_PID=$!
    fi
done
