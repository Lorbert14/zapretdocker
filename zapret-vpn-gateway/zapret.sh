#!/usr/bin/env bash

set -u

ZAPRET_DIR="/opt/zapret"
PID_DIR="/run"
MARK="0x40000000"
QNUM="220"

MODE="${APP_ZAPRET_VPN_MODE:-nfqws}"
STRATEGY="${APP_ZAPRET_VPN_STRATEGY:-general}"
ZAPRET_ALL="${APP_ZAPRET_VPN_ZAPRET_ALL:-0}"
GAMEFILTER="${APP_ZAPRET_VPN_GAMEFILTER:-0}"
IFACE="${APP_ZAPRET_VPN_IFACE:-eth0}"

IPT="$(command -v iptables-legacy || command -v iptables || true)"
IP6T="$(command -v ip6tables-legacy || command -v ip6tables || true)"

TCP_PORTS="80,443,2053,2083,2087,2096,8443"
UDP_PORTS="443,19294-19344,50000-50100"
if [ "${GAMEFILTER}" = "1" ]; then
    TCP_PORTS="${TCP_PORTS},1024-65535"
    UDP_PORTS="${UDP_PORTS},1024-65535"
fi

NFQWS_PARAMS=()

log() { echo "[zapret] $*"; }

build_params() {
    NFQWS_PARAMS=(
        "--daemon"
        "--pidfile=${PID_DIR}/nfqws.pid"
        "--qnum=${QNUM}"
        "--dpi-desync-fwmark=${MARK}"
    )

    if [ "${STRATEGY}" = "general_simple" ]; then
        NFQWS_PARAMS+=(
            "--filter-udp=443" "--hostlist=list-general.txt" "--hostlist-exclude=list-exclude.txt" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fake-quic=quic_initial_www_google_com.bin" "--new"
            "--filter-udp=19294-19344,50000-50100" "--filter-l7=discord,stun" "--dpi-desync=fake" "--dpi-desync-fake-discord=quic_initial_dbankcloud_ru.bin" "--dpi-desync-fake-stun=quic_initial_dbankcloud_ru.bin" "--dpi-desync-repeats=6" "--new"
            "--filter-tcp=2053,2083,2087,2096,8443" "--hostlist-domains=discord.media" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=tls_clienthello_www_google_com.bin" "--new"
            "--filter-tcp=443" "--hostlist=list-google.txt" "--ip-id=zero" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=tls_clienthello_www_google_com.bin" "--new"
            "--filter-tcp=80,443" "--hostlist=list-general.txt" "--hostlist-exclude=list-exclude.txt" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=stun.bin" "--dpi-desync-fake-tls=tls_clienthello_www_google_com.bin" "--dpi-desync-fake-http=tls_clienthello_max_ru.bin" "--new"
        )
        if [ "${GAMEFILTER}" = "1" ]; then
            NFQWS_PARAMS+=(
                "--filter-tcp=1024-65535" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-any-protocol=1" "--dpi-desync-cutoff=n4" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=stun.bin" "--dpi-desync-fake-tls=tls_clienthello_www_google_com.bin" "--dpi-desync-fake-http=tls_clienthello_max_ru.bin" "--new"
                "--filter-udp=1024-65535" "--dpi-desync=fake" "--dpi-desync-repeats=12" "--dpi-desync-any-protocol=1" "--dpi-desync-fake-unknown-udp=quic_initial_dbankcloud_ru.bin" "--dpi-desync-cutoff=n2"
            )
        fi
    else
        NFQWS_PARAMS+=(
            "--filter-udp=443" "--hostlist=list-general.txt" "--hostlist-exclude=list-exclude.txt" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fake-quic=quic_initial_www_google_com.bin" "--new"
            "--filter-udp=19294-19344,50000-50100" "--filter-l7=discord,stun" "--dpi-desync=fake" "--dpi-desync-fake-discord=quic_initial_dbankcloud_ru.bin" "--dpi-desync-fake-stun=quic_initial_dbankcloud_ru.bin" "--dpi-desync-repeats=6" "--new"
            "--filter-tcp=2053,2083,2087,2096,8443" "--hostlist-domains=discord.media" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=tls_clienthello_www_google_com.bin" "--new"
            "--filter-tcp=443" "--hostlist=list-google.txt" "--ip-id=zero" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=tls_clienthello_www_google_com.bin" "--new"
            "--filter-tcp=80,443" "--hostlist=list-general.txt" "--hostlist-exclude=list-exclude.txt" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=568" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=tls_clienthello_4pda_to.bin" "--new"
        )
        if [ "${GAMEFILTER}" = "1" ]; then
            NFQWS_PARAMS+=(
                "--filter-tcp=1024-65535" "--dpi-desync=multisplit" "--dpi-desync-any-protocol=1" "--dpi-desync-cutoff=n3" "--dpi-desync-split-seqovl=568" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=tls_clienthello_4pda_to.bin" "--new"
                "--filter-udp=1024-65535" "--dpi-desync=fake" "--dpi-desync-repeats=12" "--dpi-desync-any-protocol=1" "--dpi-desync-fake-unknown-udp=quic_initial_dbankcloud_ru.bin" "--dpi-desync-cutoff=n2"
            )
        fi
    fi

    if [ "${ZAPRET_ALL}" = "1" ]; then
        NFQWS_PARAMS+=(
            "--filter-tcp=80,443" "--dpi-desync=multisplit" "--dpi-desync-any-protocol=1" "--dpi-desync-cutoff=n3" "--dpi-desync-split-seqovl=568" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=tls_clienthello_4pda_to.bin" "--new"
            "--filter-udp=443" "--dpi-desync=fake" "--dpi-desync-repeats=12" "--dpi-desync-any-protocol=1" "--dpi-desync-cutoff=n2" "--dpi-desync-fake-quic=quic_initial_www_google_com.bin" "--new"
        )
    fi
}

setup_nfqueue_rules() {
    [ -z "${IPT}" ] && { log "iptables не найден"; return 1; }

    "${IPT}" -t mangle -N zapret 2>/dev/null || true
    "${IPT}" -t mangle -F zapret 2>/dev/null || true
    "${IPT}" -t mangle -D POSTROUTING -j zapret 2>/dev/null || true
    "${IPT}" -t mangle -A POSTROUTING -j zapret

    "${IPT}" -t mangle -A zapret -o "${IFACE}" -p tcp -m multiport --dports "${TCP_PORTS}" -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 -m mark ! --mark "${MARK}/${MARK}" -j NFQUEUE --queue-num "${QNUM}" --queue-bypass
    "${IPT}" -t mangle -A zapret -o "${IFACE}" -p udp -m multiport --dports "${UDP_PORTS}" -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 -m mark ! --mark "${MARK}/${MARK}" -j NFQUEUE --queue-num "${QNUM}" --queue-bypass

    "${IPT}" -t mangle -N zapret_reply 2>/dev/null || true
    "${IPT}" -t mangle -F zapret_reply 2>/dev/null || true
    "${IPT}" -t mangle -D PREROUTING -j zapret_reply 2>/dev/null || true
    "${IPT}" -t mangle -A PREROUTING -j zapret_reply

    "${IPT}" -t mangle -A zapret_reply -i "${IFACE}" -p tcp -m multiport --sports "${TCP_PORTS}" -m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:3 -m mark ! --mark "${MARK}/${MARK}" -j NFQUEUE --queue-num "${QNUM}" --queue-bypass
}

setup_tpws_rules() {
    [ -z "${IPT}" ] && { log "iptables не найден"; return 1; }
    "${IPT}" -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 988 2>/dev/null || "${IPT}" -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 988
}

clear_rules() {
    [ -z "${IPT}" ] && return 0
    "${IPT}" -t mangle -D POSTROUTING -j zapret 2>/dev/null || true
    "${IPT}" -t mangle -F zapret 2>/dev/null || true
    "${IPT}" -t mangle -X zapret 2>/dev/null || true
    "${IPT}" -t mangle -D PREROUTING -j zapret_reply 2>/dev/null || true
    "${IPT}" -t mangle -F zapret_reply 2>/dev/null || true
    "${IPT}" -t mangle -X zapret_reply 2>/dev/null || true
    "${IPT}" -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 988 2>/dev/null || true
}

stop_nfqws() {
    if [ -f "${PID_DIR}/nfqws.pid" ]; then
        kill "$(cat "${PID_DIR}/nfqws.pid")" 2>/dev/null || true
        rm -f "${PID_DIR}/nfqws.pid"
    fi
    pkill -f "nfqws" 2>/dev/null || true
}

stop_tpws() {
    if [ -f "${PID_DIR}/tpws.pid" ]; then
        kill "$(cat "${PID_DIR}/tpws.pid")" 2>/dev/null || true
        rm -f "${PID_DIR}/tpws.pid"
    fi
    pkill -f "tpws" 2>/dev/null || true
}

start_nfqws() {
    [ -x "${ZAPRET_DIR}/nfqws" ] || { log "бинарник nfqws не найден"; return 1; }
    build_params
    setup_nfqueue_rules || return 1
    cd "${ZAPRET_DIR}" || return 1
    log "Запуск nfqws (стратегия=${STRATEGY}, queue=${QNUM}, mark=${MARK})"
    "${ZAPRET_DIR}/nfqws" "${NFQWS_PARAMS[@]}" || { log "nfqws завершился с ошибкой"; return 1; }
}

start_tpws() {
    [ -x "${ZAPRET_DIR}/tpws" ] || { log "бинарник tpws не найден"; return 1; }
    setup_tpws_rules || return 1
    cd "${ZAPRET_DIR}" || return 1
    log "Запуск tpws (REDIRECT tcp/80 -> 988)"
    "${ZAPRET_DIR}/tpws" --daemon --pidfile="${PID_DIR}/tpws.pid" --port=988 --split-pos=2 --hostlist=list-general.txt --hostlist-exclude=list-exclude.txt || { log "tpws завершился с ошибкой"; return 1; }
}

status() {
    if pgrep -f "${ZAPRET_DIR}/nfqws" >/dev/null 2>&1 || pgrep -x nfqws >/dev/null 2>&1; then
        echo "nfqws: running"
    else
        echo "nfqws: stopped"
    fi
    if pgrep -f "${ZAPRET_DIR}/tpws" >/dev/null 2>&1 || pgrep -x tpws >/dev/null 2>&1; then
        echo "tpws: running"
    else
        echo "tpws: stopped"
    fi
    if [ -n "${IPT}" ]; then
        if "${IPT}" -t mangle -L zapret -n 2>/dev/null | grep -q NFQUEUE; then
            echo "iptables: NFQUEUE rules active"
        else
            echo "iptables: no NFQUEUE rules"
        fi
    fi
}

start() {
    stop
    case "${MODE}" in
        tpws)
            start_tpws
            ;;
        both)
            start_nfqws
            start_tpws
            ;;
        *)
            start_nfqws
            ;;
    esac
}

stop() {
    stop_nfqws
    stop_tpws
    clear_rules
    log "zapret остановлен"
}

cmd="${1:-status}"
case "${cmd}" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    *) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
