#!/usr/bin/env python3

import ipaddress
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

DATA_DIR = "/data"
WG_DIR = os.path.join(DATA_DIR, "wg")
PEERS_FILE = os.path.join(WG_DIR, "peers.json")
ENDPOINT_FILE = os.path.join(DATA_DIR, "endpoint.txt")
ROUTES_FILE = os.path.join(DATA_DIR, "routes.json")
GATEWAY_IP_FILE = os.path.join(DATA_DIR, "gateway_ip")
WEB_ROOT = "/opt/zapret-gateway/web"
APP_DIR = "/opt/zapret-gateway"

BIND_ADDR = os.environ.get("APP_ZAPRET_VPN_BIND", "0.0.0.0")
PORT = 8095
WG_PORT = os.environ.get("APP_ZAPRET_VPN_WG_PORT", "51820")
WG_SUBNET = os.environ.get("APP_ZAPRET_VPN_WG_SUBNET", "10.11.12.0/24")
CLIENT_DNS = os.environ.get("APP_ZAPRET_VPN_CLIENT_DNS", "1.1.1.1")
DEFAULT_PEER = os.environ.get("APP_ZAPRET_VPN_DEFAULT_PEER", "iphone")
TOKEN = os.environ.get("APP_ZAPRET_VPN_TOKEN", "").strip()
VERSION = "1.0.0"

PEERS_LOCK = threading.Lock()
ROUTES_LOCK = threading.Lock()


def run(cmd, input_text=None, binary=False, timeout=60):
    kw = {
        "capture_output": True,
        "text": not binary,
        "timeout": timeout,
    }
    if input_text is not None:
        kw["input"] = input_text
    try:
        return subprocess.run(cmd, **kw)
    except (subprocess.SubprocessError, OSError):
        return None


def sh(cmd):
    r = run(cmd)
    if r is None or r.returncode != 0:
        return False, (r.stderr if r and r.stderr else "")[:2000]
    return True, (r.stdout or "").strip()


def is_running(name):
    r = run(["pgrep", "-f", "/opt/zapret/" + name])
    return r is not None and r.returncode == 0


def gateway_ip():
    try:
        with open(GATEWAY_IP_FILE) as f:
            v = f.read().strip()
        if v and v != "0.0.0.0":
            return v
    except OSError:
        pass
    r = run(["ip", "-4", "-o", "addr", "show", "dev", "eth0"])
    if r and r.stdout:
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", r.stdout)
        if m:
            return m.group(1)
    return "unknown"


def ensure_wg():
    os.makedirs(WG_DIR, exist_ok=True)
    key_file = os.path.join(WG_DIR, "server.key")
    if not os.path.exists(key_file):
        r = run(["wg", "genkey"])
        if r and r.stdout.strip():
            with open(key_file, "w") as f:
                f.write(r.stdout.strip() + "\n")
            os.chmod(key_file, 0o600)
    try:
        with open(key_file) as f:
            priv = f.read().strip()
    except OSError:
        priv = ""
    pub = ""
    r = run(["wg", "pubkey"], input_text=priv)
    if r and r.stdout.strip():
        pub = r.stdout.strip()
        with open(os.path.join(WG_DIR, "server.pub"), "w") as f:
            f.write(pub + "\n")
    return priv, pub


def load_peers():
    try:
        with open(PEERS_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_peers(peers):
    with PEERS_LOCK:
        tmp = PEERS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(peers, f, indent=2)
        os.replace(tmp, PEERS_FILE)


def load_routes():
    try:
        with open(ROUTES_FILE) as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("containers"), list):
            return data
    except (OSError, ValueError):
        pass
    return {"containers": []}


def save_routes(routes):
    with ROUTES_LOCK:
        tmp = ROUTES_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(routes, f, indent=2)
        os.replace(tmp, ROUTES_FILE)


def route_state():
    state_file = os.path.join(DATA_DIR, "route_state.json")
    try:
        with open(state_file) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def alloc_address(peers):
    net = ipaddress.ip_network(WG_SUBNET, strict=False)
    used = set()
    for p in peers.values():
        try:
            used.add(ipaddress.ip_address(p["address"].split("/")[0]))
        except (KeyError, ValueError):
            pass
    used.add(net.network_address + 1)
    for i in range(2, max(3, net.num_addresses - 1)):
        ip = net.network_address + i
        if ip not in used:
            return str(ip) + "/32"
    return None


def get_endpoint():
    try:
        with open(ENDPOINT_FILE) as f:
            v = f.read().strip()
        if v:
            return v
    except OSError:
        pass
    return os.environ.get("APP_ZAPRET_VPN_ENDPOINT", "umbrel.local").strip()


def set_endpoint(value):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(ENDPOINT_FILE, "w") as f:
        f.write((value or "").strip() + "\n")
    return get_endpoint()


def client_config(name, peers, server_pub):
    p = peers[name]
    ep = get_endpoint()
    return (
        "[Interface]\n"
        "PrivateKey = {privkey}\n"
        "Address = {address}\n"
        "DNS = {dns}\n\n"
        "[Peer]\n"
        "PublicKey = {pub}\n"
        "AllowedIPs = 0.0.0.0/0\n"
        "Endpoint = {ep}:{port}\n"
        "PersistentKeepalive = 25\n"
    ).format(privkey=p["privkey"], address=p["address"], dns=CLIENT_DNS, pub=server_pub, ep=ep, port=WG_PORT)


def wg_sync(peers):
    sync_file = os.path.join(WG_DIR, "sync.conf")
    lines = []
    for p in peers.values():
        lines.append("[Peer]")
        lines.append("PublicKey = %s" % p["pubkey"])
        lines.append("AllowedIPs = %s" % p["address"])
        lines.append("")
    with open(sync_file, "w") as f:
        f.write("\n".join(lines))
    ok, err = sh(["wg", "syncconf", "wg0", sync_file])
    if not ok:
        sh(["wg-quick", "up", os.path.join(WG_DIR, "wg0.conf")])
        sh(["wg", "syncconf", "wg0", sync_file])


def wg_status():
    r = run(["wg", "show", "wg0", "dump"])
    peers = []
    up = False
    if r and r.returncode == 0:
        up = True
        lines = r.stdout.strip().splitlines()
        for line in lines[1:]:
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            peers.append({
                "pubkey": parts[0],
                "endpoint": parts[2] if len(parts) > 2 else "",
                "allowed_ips": parts[3] if len(parts) > 3 else "",
                "latest_handshake": int(parts[4]) if len(parts) > 4 and parts[4].isdigit() else 0,
                "transfer_rx": int(parts[5]) if len(parts) > 5 and parts[5].isdigit() else 0,
                "transfer_tx": int(parts[6]) if len(parts) > 6 and parts[6].isdigit() else 0,
            })
    return {"up": up, "peers": peers}


def print_qr_log(config_text, name):
    r = run(["qrencode", "-t", "ANSIUTF8", "-s", "4", "-o", "-"], input_text=config_text)
    if r and r.returncode == 0 and r.stdout:
        print("")
        print("================= WireGuard QR (%s) =================" % name)
        print(r.stdout)
        print("=====================================================")
        print("Отсканируйте QR в приложении WireGuard на iPhone,", flush=True)
        print("или скачайте конфиг из веб-панели.", flush=True)


def qr_png(config_text):
    r = run(["qrencode", "-t", "PNG", "-s", "8", "-m", "2", "-o", "-"], input_text=config_text, binary=True)
    if r and r.returncode == 0:
        return r.stdout
    return None


def create_peer(name, peers, server_pub, log_qr=True):
    name = re.sub(r"[^a-zA-Z0-9._-]", "", name or "") or "peer"
    if name in peers:
        return None
    r = run(["wg", "genkey"])
    if not r or not r.stdout.strip():
        return None
    priv = r.stdout.strip()
    r2 = run(["wg", "pubkey"], input_text=priv)
    if not r2 or not r2.stdout.strip():
        return None
    addr = alloc_address(peers)
    if not addr:
        return None
    peers[name] = {
        "pubkey": r2.stdout.strip(),
        "privkey": priv,
        "address": addr,
        "created": int(time.time()),
    }
    save_peers(peers)
    wg_sync(peers)
    conf = client_config(name, peers, server_pub)
    if log_qr:
        print_qr_log(conf, name)
    return conf


def delete_peer(name, peers):
    if name not in peers:
        return False
    del peers[name]
    save_peers(peers)
    wg_sync(peers)
    return True


def docker_ps():
    r = run(["docker", "ps", "--format", "{{json .}}"])
    items = []
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            try:
                items.append(json.loads(line))
            except ValueError:
                pass
    return items


def containers_info():
    items = docker_ps()
    ids = [c.get("ID", "") for c in items if c.get("ID")]
    ip_map = {}
    if ids:
        r = run(["docker", "inspect"] + ids)
        if r and r.returncode == 0:
            try:
                for c in json.loads(r.stdout):
                    ip = ""
                    nets = (c.get("NetworkSettings") or {}).get("Networks") or {}
                    for n in nets.values():
                        if n.get("IPAddress"):
                            ip = n["IPAddress"]
                            break
                    ip_map[c.get("Id", "")] = ip
            except ValueError:
                pass
    out = []
    for c in items:
        out.append({
            "name": (c.get("Names") or "?").lstrip("/"),
            "id": c.get("ID", ""),
            "image": c.get("Image", ""),
            "status": c.get("Status", ""),
            "ip": ip_map.get(c.get("ID", ""), ""),
        })
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "zapret-vpn-gateway/" + VERSION

    def log_message(self, fmt, *args):
        pass

    def _auth_ok(self):
        if not TOKEN:
            return True
        qs = parse_qs(urlparse(self.path).query)
        if qs.get("token", [""])[0] == TOKEN:
            return True
        if self.headers.get("X-Auth-Token", "") == TOKEN:
            return True
        return False

    def _send(self, code, body, ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8"))

    def _error(self, msg, code=400):
        self._json({"error": msg}, code)

    def _body_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    def _peer_by_name(self, name):
        peers = load_peers()
        if name not in peers:
            self._error("пир не найден", 404)
            return None, None
        return name, peers

    def _api_status(self):
        peers = load_peers()
        _, server_pub = ensure_wg()
        wg = wg_status()
        wg_peers = {}
        for name, p in peers.items():
            wg_peers[name] = {
                "address": p["address"],
                "created": p.get("created", 0),
            }
            for wp in wg["peers"]:
                if wp["pubkey"] == p["pubkey"]:
                    wg_peers[name].update({
                        "endpoint": wp["endpoint"],
                        "latest_handshake": wp["latest_handshake"],
                        "transfer_rx": wp["transfer_rx"],
                        "transfer_tx": wp["transfer_tx"],
                    })
                    break
        return {
            "version": VERSION,
            "gateway_ip": gateway_ip(),
            "endpoint": get_endpoint(),
            "wg_port": WG_PORT,
            "wg_subnet": WG_SUBNET,
            "client_dns": CLIENT_DNS,
            "server_pubkey": server_pub,
            "wg_up": wg["up"],
            "wg_peers": wg_peers,
            "zapret_mode": os.environ.get("APP_ZAPRET_VPN_MODE", "nfqws"),
            "zapret_strategy": os.environ.get("APP_ZAPRET_VPN_STRATEGY", "general"),
            "nfqws_running": is_running("nfqws"),
            "tpws_running": is_running("tpws"),
            "routed_containers": load_routes()["containers"],
            "route_state": route_state(),
        }

    def _api_containers(self):
        routed = set(load_routes()["containers"])
        state = route_state()
        out = []
        for c in containers_info():
            out.append({
                **c,
                "routed": c["name"] in routed,
                "applied": c["name"] in state,
            })
        return out

    def do_GET(self):
        if not self._auth_ok():
            self._json({"error": "unauthorized"}, 401)
            return
        u = urlparse(self.path)
        path = unquote(u.path)

        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(WEB_ROOT, "index.html"), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError:
                self._error("ui not found", 404)
            return

        if path == "/api/health":
            self._json({"ok": True})
            return

        if path == "/api/status":
            self._json(self._api_status())
            return

        if path == "/api/containers":
            self._json({"containers": self._api_containers()})
            return

        if path == "/api/routes":
            self._json({
                "containers": load_routes()["containers"],
                "state": route_state(),
                "gateway_ip": gateway_ip(),
            })
            return

        if path == "/api/wg":
            self._json(self._api_status())
            return

        m = re.match(r"^/api/wg/peers/([^/]+)/config$", path)
        if m:
            name = unquote(m.group(1))
            peers = load_peers()
            if name not in peers:
                self._error("пир не найден", 404)
                return
            _, server_pub = ensure_wg()
            conf = client_config(name, peers, server_pub)
            self._send(
                200,
                conf.encode("utf-8"),
                "text/plain; charset=utf-8",
                {"Content-Disposition": 'attachment; filename="%s.conf"' % name},
            )
            return

        m = re.match(r"^/api/wg/peers/([^/]+)/qr.png$", path)
        if m:
            name = unquote(m.group(1))
            peers = load_peers()
            if name not in peers:
                self._error("пир не найден", 404)
                return
            _, server_pub = ensure_wg()
            conf = client_config(name, peers, server_pub)
            png = qr_png(conf)
            if png is None:
                self._error("не удалось сгенерировать QR", 500)
                return
            self._send(200, png, "image/png")
            return

        self._error("not found", 404)

    def do_POST(self):
        if not self._auth_ok():
            self._json({"error": "unauthorized"}, 401)
            return
        u = urlparse(self.path)
        path = unquote(u.path)
        body = self._body_json()

        if path == "/api/wg/peers":
            name = str(body.get("name", "")).strip()
            if not name:
                self._error("укажите имя пира", 400)
                return
            peers = load_peers()
            _, server_pub = ensure_wg()
            if name in peers:
                self._error("пир с таким именем уже существует", 409)
                return
            conf = create_peer(name, peers, server_pub, log_qr=True)
            if conf is None:
                self._error("не удалось создать пира", 500)
                return
            self._json({"name": name, "config": conf, "qr": "/api/wg/peers/%s/qr.png" % name})
            return

        if path == "/api/routes":
            action = str(body.get("action", "")).strip()
            name = str(body.get("name", "")).strip()
            if not action or not name:
                self._error("нужны поля action и name", 400)
                return
            if action == "add":
                routes = load_routes()
                if name not in routes["containers"]:
                    routes["containers"].append(name)
                    save_routes(routes)
                ok, err = sh([os.path.join(APP_DIR, "route-manager.sh"), "apply", name])
                if not ok:
                    self._json({"result": "error", "detail": err}, 500)
                    return
                self._json({"result": "ok"})
                return
            if action == "remove":
                routes = load_routes()
                routes["containers"] = [c for c in routes["containers"] if c != name]
                save_routes(routes)
                sh([os.path.join(APP_DIR, "route-manager.sh"), "remove", name])
                self._json({"result": "ok"})
                return
            self._error("неизвестное действие: %s" % action, 400)
            return

        if path == "/api/settings":
            endpoint = str(body.get("endpoint", "")).strip()
            if endpoint:
                set_endpoint(endpoint)
            dns = str(body.get("client_dns", "")).strip()
            if dns:
                global CLIENT_DNS
                CLIENT_DNS = dns
            self._json({"endpoint": get_endpoint(), "client_dns": CLIENT_DNS})
            return

        if path == "/api/zapret":
            action = str(body.get("action", "")).strip()
            if action not in ("start", "stop", "restart"):
                self._error("действие: start|stop|restart", 400)
                return
            ok, err = sh([os.path.join(APP_DIR, "zapret.sh"), action])
            self._json({"result": "ok" if ok else "error", "detail": err})
            return

        self._error("not found", 404)

    def do_DELETE(self):
        if not self._auth_ok():
            self._json({"error": "unauthorized"}, 401)
            return
        u = urlparse(self.path)
        path = unquote(u.path)
        m = re.match(r"^/api/wg/peers/([^/]+)$", path)
        if m:
            name = unquote(m.group(1))
            peers = load_peers()
            if name not in peers:
                self._error("пир не найден", 404)
                return
            delete_peer(name, peers)
            self._json({"result": "ok"})
            return
        self._error("not found", 404)


def main():
    _, server_pub = ensure_wg()
    peers = load_peers()
    if not peers and DEFAULT_PEER and DEFAULT_PEER.lower() != "none":
        name = re.sub(r"[^a-zA-Z0-9._-]", "", DEFAULT_PEER) or "iphone"
        create_peer(name, peers, server_pub, log_qr=True)
    print("[zapret-vpn-gateway] веб-панель запущена на порту %d" % PORT, flush=True)
    print("[zapret-vpn-gateway] endpoint: %s:%s" % (get_endpoint(), WG_PORT), flush=True)
    httpd = ThreadingHTTPServer((BIND_ADDR, PORT), Handler)
    httpd.daemon_threads = True
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
