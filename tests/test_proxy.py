"""Проверка прокси целиком на поддельных серверах, без интернета и без настоящего прокси-сервера.

    python3 -I tests/test_proxy.py path/to/Razvilka

Что поднимается на 127.0.0.1:
  * два «сайта»: DIRECT (отвечает «direct ...») и VIA (отвечает «via ...»);
  * поддельный прокси-сервер: принимает CONNECT с логином test:secret и всегда ведёт на VIA,
    поэтому по ответу видно, каким путём шёл запрос;
  * поддельный DNS по HTTP: ru-site.test → российский адрес, foreign.test → зарубежный.
Прямые соединения к именам *.test подменяются на DIRECT через RAZVILKA_TEST_HOSTS.
"""
import base64
import hashlib
import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

BIN = None
BIG = os.urandom(5 * 1024 * 1024)
BIG_SHA = hashlib.sha256(BIG).hexdigest()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server(socketserver.ThreadingTCPServer):
    request_queue_size = 256
    daemon_threads = True
    allow_reuse_address = True


class Site(http.server.BaseHTTPRequestHandler):
    label = "?"
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/big":
            body = BIG
        else:
            body = f"{self.label} {self.headers.get('Host')} {self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(n)
        body = f"{self.label} posted {hashlib.sha256(data).hexdigest()}".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def start_site(label):
    handler = type(f"Site_{label}", (Site,), {"label": label})
    srv = Server(("127.0.0.1", 0), handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class Upstream:
    """Поддельный прокси-сервер: только CONNECT, логин test:secret, всегда ведёт на сайт VIA."""

    def __init__(self, via_port):
        self.via_port = via_port
        self.targets = []
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(256)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()

    def handle(self, c):
        try:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = c.recv(4096)
                if not chunk:
                    return
                data += chunk
            head, rest = data.split(b"\r\n\r\n", 1)
            lines = head.decode().split("\r\n")
            method, target, _ = lines[0].split(" ")
            headers = {k.lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:])}
            want = "Basic " + base64.b64encode(b"test:secret").decode()
            if method != "CONNECT":
                c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                return
            if headers.get("proxy-authorization") != want:
                c.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
                return
            self.targets.append(target)
            if target.startswith("blocked.test"):
                c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                return
            # DNS-запросы ведём на поддельный DNS, всё остальное — на сайт VIA
            port = DOH_PORT if target.startswith("doh.test:") else self.via_port
            r = socket.create_connection(("127.0.0.1", port))
            c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if rest:
                r.sendall(rest)
            pipe(c, r)
        except Exception:
            pass
        finally:
            pass


def pipe(a, b):
    def one(src, dst):
        try:
            while True:
                d = src.recv(65536)
                if not d:
                    break
                dst.sendall(d)
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    t = threading.Thread(target=one, args=(b, a), daemon=True)
    t.start()
    one(a, b)
    t.join(10)
    a.close()
    b.close()


DNS_ANSWERS = {
    "ru-site.test": "77.88.55.88",
    "foreign.test": "8.8.8.8",
}
DOH_QUERIES = []


class DoH(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        name = q.get("name", [""])[0]
        DOH_QUERIES.append(name)
        if name == "slow.test":
            time.sleep(0.8)
        ip = DNS_ANSWERS.get(name)
        body = {"Status": 0, "Answer": [{"name": name, "type": 1, "TTL": 300, "data": ip}]} if ip else {"Status": 3}
        if name == "slow.test":
            body = {"Status": 0, "Answer": [{"name": name, "type": 1, "TTL": 300, "data": "77.88.55.88"}]}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def start_doh():
    srv = Server(("127.0.0.1", 0), DoH)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


DOH_PORT = None


def curl(*args, timeout=20):
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    r = subprocess.run(["curl", "-sS", "--max-time", str(timeout), *args], capture_output=True, env=env, timeout=timeout + 5)
    return r.returncode, r.stdout, r.stderr.decode(errors="replace")


class ProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global DOH_PORT
        cls.direct = start_site("direct")
        cls.via = start_site("via")
        cls.doh = start_doh()
        DOH_PORT = cls.doh.server_address[1]
        cls.upstream = Upstream(cls.via.server_address[1])
        cls.dir = tempfile.mkdtemp(prefix="razvilka-test-")
        cls.cfg = os.path.join(cls.dir, "config.json")
        cls.port = free_port()
        cls.write_config()
        dp = cls.direct.server_address[1]
        env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
        env.update({
            "RAZVILKA_DIR": cls.dir,
            "RAZVILKA_DOH": f"http://doh.test:{DOH_PORT}/resolve",
            "RAZVILKA_TEST_HOSTS": ",".join(f"{h}=127.0.0.1" for h in ["shop.ru", "ru-site.test", "slow.test", "foreign.test", "unknown.test", "blocked.test"]),
        })
        cls.proc = subprocess.Popen([BIN, "--serve", "--config", cls.cfg, "--port", str(cls.port)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True)
        cls.lines = []
        first = cls.proc.stdout.readline().strip()
        cls.lines.append(first)
        assert first == f"listening {cls.port}", first
        threading.Thread(target=cls.collect, daemon=True).start()
        cls.dp = dp

    @classmethod
    def collect(cls):
        for line in cls.proc.stdout:
            cls.lines.append(line.strip())

    @classmethod
    def write_config(cls, **over):
        cfg = {"host": "127.0.0.1", "port": cls.upstream.port, "username": "test", "password": "secret",
               "mode": "rules", "directDomains": [".ru", ".su", ".рф"]}
        cfg.update(over)
        with open(cls.cfg, "w") as f:
            json.dump(cfg, f)

    @classmethod
    def reload(cls, **over):
        cls.write_config(**over)
        n = cls.lines.count("reloaded")
        cls.proc.send_signal(1)  # SIGHUP
        for _ in range(50):
            if cls.lines.count("reloaded") > n:
                return
            time.sleep(0.05)
        raise AssertionError("настройки не перечитались")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(5)

    def setUp(self):
        self.reload()
        self.upstream.targets.clear()

    def px(self):
        return f"http://127.0.0.1:{self.port}"

    def get(self, host, *extra, path="/", timeout=20):
        return curl("-p", "-x", self.px(), f"http://{host}:{self.dp}{path}", *extra, timeout=timeout)

    # --- Пути ---

    def test_connect_ru_domain_goes_direct(self):
        code, out, err = self.get("shop.ru")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"direct shop.ru"), out)
        self.assertEqual(self.upstream.targets, [])

    def test_connect_foreign_goes_via_server(self):
        code, out, err = self.get("foreign.test")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"via foreign.test"), out)
        self.assertIn(f"foreign.test:{self.dp}", self.upstream.targets)

    def test_russian_ip_by_dns_goes_direct(self):
        code, out, err = self.get("ru-site.test")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"direct ru-site.test"), out)

    def test_dns_goes_via_server(self):
        DOH_QUERIES.clear()
        self.reload(password="secret", username="test", port=self.upstream.port, directDomains=[".ru", ".su"])
        self.get("foreign.test")
        self.assertIn("foreign.test", DOH_QUERIES)
        self.assertTrue(any(t.startswith("doh.test:") for t in self.upstream.targets), self.upstream.targets)

    def test_slow_dns_still_direct(self):
        # Сервер успевает подключиться раньше, чем приходит ответ DNS: всё равно напрямую, лишнее соединение закрыто
        code, out, err = self.get("slow.test")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"direct slow.test"), out)

    def test_unknown_name_goes_via_server(self):
        code, out, err = self.get("unknown.test")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"via"), out)

    def test_local_ip_direct(self):
        code, out, err = curl("-p", "-x", self.px(), f"http://127.0.0.1:{self.dp}/x")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"direct"), out)

    def test_plain_http_rewritten(self):
        code, out, err = curl("-x", self.px(), f"http://foreign.test:{self.dp}/a?b=1")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, f"via foreign.test:{self.dp} /a?b=1".encode())
        code, out, err = curl("-x", self.px(), f"http://shop.ru:{self.dp}/p")
        self.assertEqual(out, f"direct shop.ru:{self.dp} /p".encode())

    def test_post_body(self):
        body = os.urandom(300000)
        path = os.path.join(self.dir, "body.bin")
        with open(path, "wb") as f:
            f.write(body)
        code, out, err = curl("-x", self.px(), "--data-binary", "@" + path, f"http://foreign.test:{self.dp}/post")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, f"via posted {hashlib.sha256(body).hexdigest()}".encode())

    def test_socks5(self):
        code, out, err = curl("--socks5-hostname", f"127.0.0.1:{self.port}", f"http://foreign.test:{self.dp}/s")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"via"), out)
        code, out, err = curl("--socks5-hostname", f"127.0.0.1:{self.port}", f"http://shop.ru:{self.dp}/s")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"direct"), out)
        code, out, err = curl("--socks5", f"127.0.0.1:{self.port}", f"http://127.0.0.1:{self.dp}/s")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith(b"direct"), out)

    def test_big_download_intact(self):
        for host in ["foreign.test", "shop.ru"]:
            code, out, err = self.get(host, path="/big", timeout=60)
            self.assertEqual(code, 0, err)
            self.assertEqual(hashlib.sha256(out).hexdigest(), BIG_SHA, host)

    def test_parallel(self):
        results = []

        def one(i):
            host = "foreign.test" if i % 2 else "shop.ru"
            results.append(self.get(host, path=f"/{i}"))

        threads = [threading.Thread(target=one, args=(i,)) for i in range(40)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        self.assertEqual(len(results), 40)
        self.assertTrue(all(code == 0 for code, _, _ in results), ([e for c, _, e in results if c], [l for l in self.lines if l.startswith("log fail")]))

    # --- Режимы и ошибки ---

    def test_mode_all(self):
        self.reload(mode="all")
        code, out, err = self.get("shop.ru")
        self.assertTrue(out.startswith(b"via"), out)
        code, out, err = curl("-p", "-x", self.px(), f"http://127.0.0.1:{self.dp}/x")
        self.assertTrue(out.startswith(b"direct"), out)

    def test_custom_direct_domain(self):
        self.reload(directDomains=["foreign.test"])
        code, out, err = self.get("foreign.test")
        self.assertTrue(out.startswith(b"direct"), out)

    def test_wrong_password(self):
        self.reload(password="wrong")
        code, out, err = curl("-p", "-x", self.px(), f"http://foreign.test:{self.dp}/", "-w", "%{http_connect}")
        self.assertNotEqual(code, 0)
        self.assertIn(b"502", out)
        time.sleep(0.2)
        self.assertIn("problem auth-failed", self.lines)
        self.reload()
        self.assertEqual(self.get("foreign.test")[0], 0)
        time.sleep(0.2)
        self.assertEqual(self.lines[-1] if self.lines[-1].startswith("problem") else
                         [l for l in self.lines if l.startswith("problem")][-1], "problem none")

    def test_server_down(self):
        self.reload(port=free_port())
        start = time.time()
        code, out, err = curl("-p", "-x", self.px(), f"http://foreign.test:{self.dp}/", "-w", "%{http_connect}")
        self.assertNotEqual(code, 0)
        self.assertIn(b"502", out)
        self.assertLess(time.time() - start, 10)
        # Российские сайты при этом работают
        code, out, err = self.get("shop.ru")
        self.assertTrue(out.startswith(b"direct"), out)

    def test_server_refuses_site(self):
        code, out, err = curl("-p", "-x", self.px(), f"http://blocked.test:{self.dp}/", "-w", "%{http_connect}")
        self.assertNotEqual(code, 0)
        self.assertIn(b"502", out)

    def test_garbage_request(self):
        with socket.create_connection(("127.0.0.1", self.port)) as s:
            s.sendall(b"HELLO\r\n\r\n")
            s.settimeout(5)
            self.assertTrue(s.recv(100).startswith(b"HTTP/1.1 400"))

    def test_only_loopback(self):
        # Прокси не должен быть виден из домашней сети
        out = subprocess.run(["lsof", "-nP", f"-iTCP:{self.port}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout
        self.assertIn(f"127.0.0.1:{self.port}", out)
        self.assertNotIn(f"*:{self.port}", out)

    def stats(self):
        n = len([l for l in self.lines if l.startswith("stats")])
        self.proc.send_signal(30)  # SIGUSR1
        for _ in range(50):
            got = [l for l in self.lines if l.startswith("stats")]
            if len(got) > n:
                return dict(kv.split("=") for kv in got[-1].split()[1:])
            time.sleep(0.05)
        raise AssertionError("нет ответа на SIGUSR1")

    def test_zz_no_hanging_connections(self):
        # После всех тестов (имя zz — идёт последним) все соединения должны закрыться
        for i in range(20):
            self.get("foreign.test" if i % 2 else "shop.ru", path=f"/{i}")
        curl("-x", self.px(), f"http://foreign.test:{self.dp}/plain")
        curl("--socks5-hostname", f"127.0.0.1:{self.port}", f"http://shop.ru:{self.dp}/s")
        deadline = time.time() + 5
        while time.time() < deadline:
            st = self.stats()
            # Открытым может остаться только keep-alive соединение DNS через сервер
            if int(st["active"]) <= 1:
                break
            time.sleep(0.3)
        self.assertLessEqual(int(st["active"]), 1, st)
        self.assertGreater(int(st["down"]), 5 * 1024 * 1024)

    def test_password_not_logged(self):
        log = os.path.join(self.dir, "proxy.log")
        text = open(log).read() if os.path.exists(log) else ""
        self.assertNotIn("secret", text)
        self.assertFalse(any("secret" in l for l in self.lines))


if __name__ == "__main__":
    BIN = os.path.abspath(sys.argv.pop(1))
    unittest.main(verbosity=1)
