#!/usr/bin/env bash

set -u

DATA_DIR="/data"
ROUTES_FILE="${DATA_DIR}/routes.json"
STATE_FILE="${DATA_DIR}/route_state.json"
GATEWAY_IP_FILE="${DATA_DIR}/gateway_ip"
LOCK_FILE="/run/route-manager.lock"
INTERVAL="${APP_ZAPRET_VPN_ROUTE_INTERVAL:-15}"
SELF_ID="$(hostname)"

log() { echo "[route-manager] $*"; }

gateway_ip() {
    local ip=""
    if [ -f "${GATEWAY_IP_FILE}" ]; then
        ip="$(cat "${GATEWAY_IP_FILE}" 2>/dev/null || true)"
    fi
    if [ -z "${ip}" ] || [ "${ip}" = "0.0.0.0" ]; then
        ip="$(ip -4 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    fi
    echo "${ip}"
}

self_name() {
    docker ps --filter "id=${SELF_ID}" --format '{{.Names}}' 2>/dev/null | head -n1
}

get_cid() {
    docker ps --filter "name=^/$1$" --format '{{.ID}}' 2>/dev/null | head -n1
}

get_default() {
    local cid="$1"
    docker exec --privileged "${cid}" sh -c 'command -v ip >/dev/null 2>&1 && ip route show default 2>/dev/null | head -n1' 2>/dev/null || true
}

has_ip() {
    local cid="$1"
    docker exec --privileged "${cid}" sh -c 'command -v ip >/dev/null 2>&1' 2>/dev/null
}

init_files() {
    mkdir -p "${DATA_DIR}"
    if [ ! -f "${ROUTES_FILE}" ] || ! jq -e . "${ROUTES_FILE}" >/dev/null 2>&1; then
        echo '{"containers":[]}' > "${ROUTES_FILE}"
    fi
    if [ ! -f "${STATE_FILE}" ] || ! jq -e . "${STATE_FILE}" >/dev/null 2>&1; then
        echo '{}' > "${STATE_FILE}"
    fi
    if [ -n "${APP_ZAPRET_VPN_ROUTE_CONTAINERS:-}" ]; then
        local c
        for c in ${APP_ZAPRET_VPN_ROUTE_CONTAINERS//,/ }; do
            [ -z "$c" ] && continue
            jq --arg n "$c" 'if (.containers | index($n)) == null then .containers += [$n] else . end' "${ROUTES_FILE}" > "${ROUTES_FILE}.tmp" 2>/dev/null && mv "${ROUTES_FILE}.tmp" "${ROUTES_FILE}"
        done
    fi
}

with_lock() {
    exec 9>"${LOCK_FILE}"
    flock 9
    "$@"
    local rc=$?
    flock -u 9
    return ${rc}
}

_apply() {
    local name="$1"
    local cid gw orig saved state
    cid="$(get_cid "${name}")"
    if [ -z "${cid}" ]; then
        log "контейнер '${name}' не запущен"
        return 1
    fi
    gw="$(gateway_ip)"
    if [ -z "${gw}" ] || [ "${gw}" = "0.0.0.0" ]; then
        log "IP шлюза не определён"
        return 1
    fi
    if ! has_ip "${cid}"; then
        log "контейнер '${name}': внутри нет утилиты ip — маршрут невозможен"
        return 1
    fi

    orig="$(get_default "${cid}")"
    case "${orig}" in
        *"via ${gw}"*)
            saved="$(jq -r --arg n "${name}" '.[$n].cid // empty' "${STATE_FILE}" 2>/dev/null || true)"
            if [ "${saved}" != "${cid}" ]; then
                state="{\"cid\":\"${cid}\",\"orig\":\"${orig}\",\"applied_at\":\"$(date -Iseconds)\"}"
                jq --arg n "${name}" --argjson s "${state}" '.[$n]=$s' "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
            fi
            return 0
            ;;
    esac

    if docker exec --privileged "${cid}" ip route replace default via "${gw}" 2>/dev/null; then
        log "контейнер '${name}': default via ${gw} (через zapret)"
        state="{\"cid\":\"${cid}\",\"orig\":\"${orig}\",\"applied_at\":\"$(date -Iseconds)\"}"
        jq --arg n "${name}" --argjson s "${state}" '.[$n]=$s' "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
        return 0
    fi

    log "контейнер '${name}': не удалось заменить маршрут (нет CAP_NET_ADMIN в контейнере?)"
    return 1
}

_remove() {
    local name="$1"
    local cid gw orig
    cid="$(get_cid "${name}")"
    gw="$(gateway_ip)"
    if [ -n "${cid}" ] && [ -n "${gw}" ]; then
        if has_ip "${cid}"; then
            docker exec --privileged "${cid}" ip route del default via "${gw}" 2>/dev/null || true
            orig="$(jq -r --arg n "${name}" '.[$n].orig // empty' "${STATE_FILE}" 2>/dev/null || true)"
            if [ -n "${orig}" ] && [ -z "$(get_default "${cid}")" ]; then
                docker exec --privileged "${cid}" ip route replace ${orig} 2>/dev/null || true
            fi
        fi
    fi
    jq --arg n "${name}" 'del(.[$n])' "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
    log "контейнер '${name}': маршрут через zapret отключён"
}

apply() {
    init_files
    with_lock _apply "$1"
}

remove() {
    init_files
    with_lock _remove "$1"
}

enable() {
    local name="$1"
    [ -z "${name}" ] && return 1
    init_files
    if [ "${name}" = "$(self_name)" ]; then
        log "нельзя маршрутизировать контейнер шлюза через самого себя"
        return 1
    fi
    jq --arg n "${name}" 'if (.containers | index($n)) == null then .containers += [$n] else . end' "${ROUTES_FILE}" > "${ROUTES_FILE}.tmp" 2>/dev/null && mv "${ROUTES_FILE}.tmp" "${ROUTES_FILE}"
    apply "${name}"
}

disable() {
    local name="$1"
    [ -z "${name}" ] && return 1
    init_files
    jq --arg n "${name}" '.containers -= [$n]' "${ROUTES_FILE}" > "${ROUTES_FILE}.tmp" 2>/dev/null && mv "${ROUTES_FILE}.tmp" "${ROUTES_FILE}"
    remove "${name}"
}

watch() {
    init_files
    log "демон маршрутизации запущен (интервал ${INTERVAL}s, шлюз $(gateway_ip))"
    while true; do
        jq -r '.containers[]?' "${ROUTES_FILE}" 2>/dev/null | while read -r name; do
            [ -z "${name}" ] && continue
            cid="$(get_cid "${name}")"
            [ -z "${cid}" ] && continue
            saved="$(jq -r --arg n "${name}" '.[$n].cid // empty' "${STATE_FILE}" 2>/dev/null || true)"
            if [ "${saved}" != "${cid}" ]; then
                jq --arg n "${name}" 'del(.[$n])' "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
            fi
            cur="$(get_default "${cid}")"
            case "${cur}" in
                *"via $(gateway_ip)"*) ;;
                *) with_lock _apply "${name}" ;;
            esac
        done

        jq -r 'keys[]' "${STATE_FILE}" 2>/dev/null | while read -r name; do
            if ! jq -e --arg n "${name}" '(.containers | index($n)) != null' "${ROUTES_FILE}" >/dev/null 2>&1; then
                with_lock _remove "${name}"
            fi
        done

        sleep "${INTERVAL}"
    done
}

cleanup() {
    init_files
    local name
    jq -r 'keys[]' "${STATE_FILE}" 2>/dev/null | while read -r name; do
        _remove "${name}"
    done
}

list() {
    init_files
    local self
    self="$(self_name)"
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | while IFS=$'\t' read -r name image status; do
        local routed=""
        if jq -e --arg n "${name}" '(.containers | index($n)) != null' "${ROUTES_FILE}" >/dev/null 2>&1; then
            routed="[zapret]"
        fi
        if [ "${name}" = "${self}" ]; then
            routed="${routed}[self]"
        fi
        printf '%s\t%s\t%s\t%s\n' "${name}" "${image}" "${status}" "${routed}"
    done
}

status() {
    init_files
    echo "gateway_ip: $(gateway_ip)"
    echo "enabled: $(jq -r '.containers | join(", ")' "${ROUTES_FILE}" 2>/dev/null || echo "")"
    echo "applied:"
    jq -r 'to_entries[] | "  \(.key): cid=\(.value.cid) orig=\(.value.orig)"' "${STATE_FILE}" 2>/dev/null || true
}

cmd="${1:-status}"
case "${cmd}" in
    apply) apply "${2:-}" ;;
    remove) remove "${2:-}" ;;
    enable) enable "${2:-}" ;;
    disable) disable "${2:-}" ;;
    watch) watch ;;
    cleanup) cleanup ;;
    list) list ;;
    status) status ;;
    gateway) gateway_ip ;;
    *) echo "usage: $0 {apply|remove|enable|disable <name> | watch | cleanup | list | status | gateway}"; exit 1 ;;
esac
