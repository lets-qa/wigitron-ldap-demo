import app.main as main
from app.config import load_settings
from fastapi.testclient import TestClient


def _client(env, monkeypatch, fake_run=None):
    monkeypatch.setattr(main, "SETTINGS", load_settings(env))
    if fake_run is not None:
        monkeypatch.setattr(main, "run_plan", fake_run)
    return TestClient(main.app)


def test_health_open(monkeypatch):
    c = _client({}, monkeypatch)
    assert c.get("/health").json() == {"status": "ok"}


def test_create_dry_run_returns_summary(monkeypatch):
    c = _client({}, monkeypatch)
    r = c.post("/domains", json={"fqdn": "orange.rmorse.com", "dry_run": True})
    assert r.status_code == 200
    body = r.json()
    assert body["mail_domain"] == "orange.rmorse.com"
    assert body["ou_dn"].startswith("OU=orange,OU=rmorse")
    assert body["created"]["users"] == 20       # default count


def test_user_count_out_of_range_422(monkeypatch):
    c = _client({}, monkeypatch)
    assert c.post("/domains",
                  json={"fqdn": "a.b.com", "user_count": 501}).status_code == 422
    assert c.post("/domains",
                  json={"fqdn": "a.b.com", "user_count": 0}).status_code == 422


def test_bad_fqdn_422(monkeypatch):
    c = _client({}, monkeypatch)
    assert c.post("/domains", json={"fqdn": "localhost"}).status_code == 422


def test_auth_required_when_configured(monkeypatch):
    env = {"STAFF_PORTAL_USER": "staff", "STAFF_PORTAL_PASS": "pw"}
    c = _client(env, monkeypatch)
    assert c.post("/domains", json={"fqdn": "a.b.com", "dry_run": True}).status_code == 401
    assert c.post("/domains", json={"fqdn": "a.b.com", "dry_run": True},
                  auth=("staff", "bad")).status_code == 401
    assert c.get("/domains").status_code == 401
    assert c.get("/health").status_code == 200
    ok = c.post("/domains", json={"fqdn": "a.b.com", "dry_run": True},
                auth=("staff", "pw"))
    assert ok.status_code == 200
