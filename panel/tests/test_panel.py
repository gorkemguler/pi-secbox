"""Panel testleri. Gerçek araç çalıştırmaz: panel/demo/bin altındaki sahte
pisec ve docker kullanılıyor, veriler geçici bir dizine kopyalanıyor.

    python3 -m unittest discover -s panel/tests
"""
import os
import re
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PANEL = HERE.parent
DEMO = PANEL / "demo"

WORK = Path(tempfile.mkdtemp(prefix="pisec-panel-test-"))
shutil.copytree(DEMO / "data", WORK, dirs_exist_ok=True)
os.environ.update({
    "PISEC_OUT": str(WORK / "pisec-sonuclar"),
    "PISEC_STATE": str(WORK / "state"),
    "PISEC_APPS": str(WORK / "apps"),
    "PISEC_CONF_DIR": str(WORK / "conf"),
    "PISEC_UFW_CONF": str(WORK / "ufw.conf"),
    "PISEC_BIN": str(DEMO / "bin" / "pisec"),
    "PISEC_HOSTNAME": "pisecbox",
    "PATH": f"{DEMO / 'bin'}:{os.environ['PATH']}",
})
os.environ.pop("PISEC_PANEL_DEMO", None)
sys.path.insert(0, str(PANEL))

import app as panel  # noqa: E402

PASSWORD = "dogru-parola-123"


class PanelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        panel.save_conf({"password_hash": panel.generate_password_hash(PASSWORD),
                         "secret_key": "test", "port": 8090})
        cls.app = panel.create_app_instance(demo=False)
        cls.app.config["TESTING"] = True

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(WORK, ignore_errors=True)

    def setUp(self):
        panel._failed_logins.clear()
        self.client = self.app.test_client()

    def csrf(self, path="/login"):
        html = self.client.get(path).get_data(as_text=True)
        return re.search(r'name="csrf" value="([a-f0-9]+)"', html).group(1)

    def login(self):
        r = self.client.post("/login", data={"csrf": self.csrf(), "password": PASSWORD})
        self.assertEqual(r.status_code, 302)

    # --- Giriş ve oturum ---

    def test_requires_login(self):
        r = self.client.get("/")
        self.assertEqual(r.status_code, 302)
        self.assertIn("/login", r.headers["Location"])
        self.assertEqual(self.client.get("/api/tor").status_code, 401)

    def test_wrong_password(self):
        r = self.client.post("/login", data={"csrf": self.csrf(), "password": "yanlis"})
        self.assertEqual(r.status_code, 401)

    def test_login_rate_limited(self):
        token = self.csrf()
        for _ in range(panel.LOGIN_MAX_FAILURES):
            self.client.post("/login", data={"csrf": token, "password": "yanlis"})
        r = self.client.post("/login", data={"csrf": token, "password": PASSWORD})
        self.assertEqual(r.status_code, 429)

    def test_post_without_csrf_rejected(self):
        self.login()
        r = self.client.post("/scope", data={"target": "hedef.com", "permission": "1"})
        self.assertEqual(r.status_code, 400)

    def test_open_redirect_blocked(self):
        r = self.client.post("/login?next=//kotu.example", data={"csrf": self.csrf(), "password": PASSWORD})
        self.assertEqual(r.headers["Location"], "/")

    def test_security_headers(self):
        r = self.client.get("/login")
        self.assertIn("default-src 'self'", r.headers["Content-Security-Policy"])
        self.assertEqual(r.headers["X-Frame-Options"], "DENY")
        self.assertEqual(r.headers["X-Content-Type-Options"], "nosniff")

    def test_pages_render(self):
        self.login()
        for path in ["/", "/jobs", "/results", "/scope", "/schedules", "/docker", "/publish", "/system",
                     "/results/hedef.com/20261030-142210-web", "/docker/logs?app=blog"]:
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 200)

    # --- Sonuçlar ---

    def test_summary_escapes_html_and_links(self):
        html = str(panel.render_summary(
            "- https://x [200] [<script>alert(1)</script>]\n- [tikla](javascript:alert(1))\n"
            "| a | b |\n|---|---|\n| <img src=x onerror=alert(1)> | `kod` |\n"))
        self.assertNotIn("<script>", html)
        self.assertNotIn("<img", html)
        self.assertNotIn("<a ", html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("<code>kod</code>", html)
        self.assertIn("<table>", html)

    def test_result_files_are_plain_text(self):
        self.login()
        r = self.client.get("/results/hedef.com/20261030-142210-web/headers.txt")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.headers["Content-Type"].startswith("text/plain"))
        r.close()

    def test_path_traversal_blocked(self):
        self.login()
        for path in ["/results/hedef.com/..%2f..%2fconf/panel.json",
                     "/results/..%2fconf/x/panel.json",
                     "/results/hedef.com/20261030-142210-web/..%2f..%2f..%2fconf%2fpanel.json",
                     "/results/hedef.com/20261030-142210-web/.hidden"]:
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 404)

    # --- Taramalar ---

    def test_job_rejects_option_injection(self):
        self.login()
        r = self.client.post("/jobs", data={"csrf": self.csrf("/jobs"), "cmd": "scan", "target": "-oN/tmp/x"})
        self.assertEqual(r.status_code, 400)

    def test_job_requires_scope(self):
        self.login()
        r = self.client.post("/jobs", data={"csrf": self.csrf("/jobs"), "cmd": "scan", "target": "baskasi.com"})
        self.assertEqual(r.status_code, 409)
        self.assertIn("Kapsama ekle", r.get_data(as_text=True))

    def test_job_runs_and_links_result(self):
        self.login()
        r = self.client.post("/jobs", data={"csrf": self.csrf("/jobs"), "cmd": "scan",
                                            "target": "hedef.com", "tor": "1", "ports": "22,80"})
        self.assertEqual(r.status_code, 302)
        jid = r.headers["Location"].rsplit("/", 1)[1]
        job = panel.read_job(jid)
        self.assertEqual(job["argv"][1:], ["scan", "hedef.com", "--tor", "-p", "22,80"])
        for _ in range(50):
            data = self.client.get(f"/api/jobs/{jid}").get_json()
            if data["status"] != "running":
                break
            time.sleep(0.1)
        self.assertEqual(data["status"], "done")
        self.assertIn("Nmap done", self.client.get(f"/api/jobs/{jid}").get_json()["text"])
        self.assertIsNotNone(data["run_url"])

    # --- Docker ---

    def test_unsafe_ports_detected(self):
        bad = panel.unsafe_port_lines('ports:\n  - "8080:80"\n  - 0.0.0.0:9000:9000\n  - "127.0.0.1:8081:80"\n')
        self.assertEqual(bad, ['- "8080:80"', "- 0.0.0.0:9000:9000"])

    def test_create_app_refuses_public_port(self):
        self.login()
        self.client.post("/docker", data={"csrf": self.csrf("/docker"), "action": "create", "app": "acik",
                                          "compose": 'services:\n  w:\n    image: nginx\n    ports:\n      - "8080:80"\n'})
        self.assertFalse((WORK / "apps" / "acik").exists())

    def test_create_app(self):
        self.login()
        self.client.post("/docker", data={"csrf": self.csrf("/docker"), "action": "create", "app": "deneme",
                                          "compose": panel.COMPOSE_TEMPLATE})
        self.assertTrue((WORK / "apps" / "deneme" / "compose.yaml").is_file())
        self.assertTrue((WORK / "apps" / "deneme" / "site" / "index.html").is_file())

    def test_container_action_needs_known_id(self):
        self.login()
        r = self.client.post("/docker", data={"csrf": self.csrf("/docker"), "action": "stop", "id": "a" * 64},
                             follow_redirects=True)
        self.assertIn("Konteyner bulunamadı", r.get_data(as_text=True))


if __name__ == "__main__":
    unittest.main()
