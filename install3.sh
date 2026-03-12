#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-${1:-}}"
USERNAME="${USERNAME:-${2:-}}"
PASSWORD="${PASSWORD:-${3:-}}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行，或使用 sudo bash install.sh ..."
  exit 1
fi

if [ -z "${PORT}" ] || [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]; then
  echo "用法:"
  echo "  $0 <port> <username> <password>"
  echo "或:"
  echo "  PORT=13301 USERNAME=user PASSWORD=pass $0"
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "端口不合法: $PORT"
  exit 1
fi

APP_DIR="/opt/py-socks5"
SERVICE_NAME="py-socks5"

echo "[1/6] 安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y python3

echo "[2/6] 创建目录..."
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"

echo "[3/6] 写入配置文件..."
cat > "${APP_DIR}/config.json" <<EOF
{
  "listen_host": "0.0.0.0",
  "listen_port": ${PORT},
  "username": "${USERNAME}",
  "password": "${PASSWORD}",
  "buffer_size": 65536,
  "timeout": 300
}
EOF
chmod 600 "${APP_DIR}/config.json"

echo "[4/6] 写入 Python 服务..."
cat > "${APP_DIR}/socks5_server.py" <<'PYEOF'
#!/usr/bin/env python3
import socket
import struct
import threading
import select
import json
import ipaddress

CONFIG_PATH = "/opt/py-socks5/config.json"

def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    return {
        "LISTEN_HOST": cfg.get("listen_host", "0.0.0.0"),
        "LISTEN_PORT": int(cfg["listen_port"]),
        "USERNAME": str(cfg["username"]),
        "PASSWORD": str(cfg["password"]),
        "BUFFER_SIZE": int(cfg.get("buffer_size", 65536)),
        "TIMEOUT": int(cfg.get("timeout", 300)),
    }

CFG = load_config()
LISTEN_HOST = CFG["LISTEN_HOST"]
LISTEN_PORT = CFG["LISTEN_PORT"]
USERNAME = CFG["USERNAME"]
PASSWORD = CFG["PASSWORD"]
BUFFER_SIZE = CFG["BUFFER_SIZE"]
TIMEOUT = CFG["TIMEOUT"]

def is_ip_allowed(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
        if addr.is_loopback or addr.is_multicast or addr.is_unspecified:
            return False
        if addr.version == 4:
            blocked = [
                ipaddress.ip_network("10.0.0.0/8"),
                ipaddress.ip_network("127.0.0.0/8"),
                ipaddress.ip_network("169.254.0.0/16"),
                ipaddress.ip_network("172.16.0.0/12"),
                ipaddress.ip_network("192.168.0.0/16"),
                ipaddress.ip_network("100.64.0.0/10"),
                ipaddress.ip_network("224.0.0.0/4"),
                ipaddress.ip_network("240.0.0.0/4"),
            ]
            return not any(addr in net for net in blocked)
        if addr.version == 6:
            if addr.is_private or addr.is_link_local or addr.is_site_local:
                return False
        return True
    except Exception:
        return False

def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("connection closed")
        data += chunk
    return data

def send_socks_reply(sock, rep, bind_addr="0.0.0.0", bind_port=0):
    try:
        addr_part = socket.inet_aton(bind_addr)
        atyp = 1
    except OSError:
        atyp = 1
        addr_part = socket.inet_aton("0.0.0.0")
    reply = b"\x05" + bytes([rep]) + b"\x00" + bytes([atyp]) + addr_part + struct.pack("!H", bind_port)
    sock.sendall(reply)

def relay_loop(client, remote):
    sockets = [client, remote]
    try:
        while True:
            r, _, _ = select.select(sockets, [], [], TIMEOUT)
            if not r:
                break
            for s in r:
                data = s.recv(BUFFER_SIZE)
                if not data:
                    return
                if s is client:
                    remote.sendall(data)
                else:
                    client.sendall(data)
    finally:
        try:
            client.close()
        except:
            pass
        try:
            remote.close()
        except:
            pass

def handle_client(conn, addr):
    conn.settimeout(TIMEOUT)
    remote = None
    try:
        header = recv_exact(conn, 2)
        ver, nmethods = header[0], header[1]
        if ver != 5:
            return

        methods = recv_exact(conn, nmethods)
        if 2 not in methods:
            conn.sendall(b"\x05\xff")
            return

        conn.sendall(b"\x05\x02")

        auth_ver = recv_exact(conn, 1)
        if auth_ver != b"\x01":
            conn.sendall(b"\x01\x01")
            return

        ulen = recv_exact(conn, 1)[0]
        username = recv_exact(conn, ulen).decode("utf-8", errors="ignore")
        plen = recv_exact(conn, 1)[0]
        password = recv_exact(conn, plen).decode("utf-8", errors="ignore")

        if username != USERNAME or password != PASSWORD:
            conn.sendall(b"\x01\x01")
            return

        conn.sendall(b"\x01\x00")

        req = recv_exact(conn, 4)
        ver, cmd, _, atyp = req
        if ver != 5:
            return

        if atyp == 1:
            dst_addr = socket.inet_ntoa(recv_exact(conn, 4))
            family = socket.AF_INET
        elif atyp == 3:
            domain_len = recv_exact(conn, 1)[0]
            dst_addr = recv_exact(conn, domain_len).decode("utf-8", errors="ignore")
            family = None
        elif atyp == 4:
            dst_addr = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
            family = socket.AF_INET6
        else:
            send_socks_reply(conn, 8)
            return

        dst_port = struct.unpack("!H", recv_exact(conn, 2))[0]

        if cmd != 1:
            send_socks_reply(conn, 7)
            return

        connect_host = dst_addr

        if atyp == 3:
            try:
                infos = socket.getaddrinfo(dst_addr, dst_port, socket.AF_UNSPEC, socket.SOCK_STREAM)
                chosen = None
                for info in infos:
                    fam, socktype, proto, canonname, sockaddr = info
                    ip = sockaddr[0]
                    if is_ip_allowed(ip):
                        chosen = (fam, sockaddr)
                        break
                if not chosen:
                    send_socks_reply(conn, 2)
                    return
                family, sockaddr = chosen
                connect_host = sockaddr[0]
            except Exception:
                send_socks_reply(conn, 4)
                return
        else:
            if not is_ip_allowed(dst_addr):
                send_socks_reply(conn, 2)
                return

        remote = socket.socket(family, socket.SOCK_STREAM)
        remote.settimeout(TIMEOUT)
        remote.connect((connect_host, dst_port))

        local = remote.getsockname()
        bind_ip = local[0]
        bind_port = local[1]

        try:
            socket.inet_aton(bind_ip)
        except OSError:
            bind_ip = "0.0.0.0"

        send_socks_reply(conn, 0, bind_ip, bind_port)
        relay_loop(conn, remote)

    except Exception:
        try:
            send_socks_reply(conn, 1)
        except:
            pass
    finally:
        try:
            conn.close()
        except:
            pass
        if remote:
            try:
                remote.close()
            except:
                pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(256)
    print(f"SOCKS5 server listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    try:
        while True:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            t.start()
    finally:
        server.close()

if __name__ == "__main__":
    main()
PYEOF

chmod 700 "${APP_DIR}/socks5_server.py"

echo "[5/6] 写入 systemd 服务..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Python SOCKS5 Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/socks5_server.py
Restart=always
RestartSec=3
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "[6/6] 启动服务..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "完成"
echo "状态: systemctl status ${SERVICE_NAME}"
echo "日志: journalctl -u ${SERVICE_NAME} -f"
echo "监听检查: ss -lntp | grep ${PORT}"
