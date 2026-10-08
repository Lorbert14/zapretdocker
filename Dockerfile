FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    ZAPRET_VERSION=v72.9 \
    FLOWSEAL_REV=ef19845a801e4e743f7bdfdbd58f9745c6adbd60

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gzip \
        iproute2 \
        ipset \
        iptables \
        jq \
        libmnl0 \
        libnetfilter-queue1 \
        libnfnetlink1 \
        procps \
        python3 \
        qrencode \
        tar \
        wireguard-tools \
        docker.io \
        zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

RUN set -eux; \
    mkdir -p /opt/zapret /tmp/zapret-dl; \
    curl -fsSL "https://github.com/bol-van/zapret/releases/download/${ZAPRET_VERSION}/zapret-${ZAPRET_VERSION}.tar.gz" -o /tmp/zapret-dl/zapret.tar.gz; \
    tar -xzf /tmp/zapret-dl/zapret.tar.gz -C /tmp/zapret-dl; \
    case "$(uname -m)" in \
        x86_64)  ZP=linux-x86_64 ;; \
        aarch64) ZP=linux-arm64 ;; \
        armv7l)  ZP=linux-arm ;; \
        *)       ZP=linux-x86_64 ;; \
    esac; \
    NFQWS=$(find /tmp/zapret-dl -type f -path "*/binaries/${ZP}/nfqws" | head -n1); \
    TPWS=$(find /tmp/zapret-dl -type f -path "*/binaries/${ZP}/tpws" | head -n1); \
    test -n "$NFQWS" && test -n "$TPWS"; \
    cp "$NFQWS" /opt/zapret/nfqws; \
    cp "$TPWS" /opt/zapret/tpws; \
    chmod +x /opt/zapret/nfqws /opt/zapret/tpws; \
    rm -rf /tmp/zapret-dl

RUN set -eux; \
    cd /opt/zapret; \
    BASE="https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/${FLOWSEAL_REV}"; \
    for f in list-general.txt list-google.txt list-exclude.txt; do \
        curl -fsSL "${BASE}/lists/${f}" -o "${f}"; \
    done; \
    for f in quic_initial_www_google_com.bin tls_clienthello_www_google_com.bin tls_clienthello_4pda_to.bin ACTIVE_DISCORD_UDP.bin ACTIVE_GAME_UDP.bin; do \
        curl -fsSL "${BASE}/bin/${f}" -o "${f}"; \
    done; \
    chmod 644 /opt/zapret/*.txt /opt/zapret/*.bin

RUN mkdir -p /opt/zapret-gateway/web /data/wg

COPY entrypoint.sh route-manager.sh zapret.sh server.py /opt/zapret-gateway/
COPY web/ /opt/zapret-gateway/web/
RUN chmod +x /opt/zapret-gateway/entrypoint.sh /opt/zapret-gateway/route-manager.sh /opt/zapret-gateway/zapret.sh

EXPOSE 8095/tcp 51820/udp

VOLUME ["/data"]

ENTRYPOINT ["/opt/zapret-gateway/entrypoint.sh"]
