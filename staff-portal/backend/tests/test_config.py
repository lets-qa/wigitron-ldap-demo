import pytest
from app.config import load_settings, auth_enabled


def test_default_no_auth_binds_loopback():
    s = load_settings({})
    assert auth_enabled(s) is False
    assert s.bind_host == "127.0.0.1"


def test_auth_enabled_binds_any():
    s = load_settings({"STAFF_PORTAL_USER": "staff", "STAFF_PORTAL_PASS": "x"})
    assert auth_enabled(s) is True
    assert s.bind_host == "0.0.0.0"


def test_partial_auth_is_off():
    s = load_settings({"STAFF_PORTAL_USER": "staff"})  # no PASS
    assert auth_enabled(s) is False
    assert s.bind_host == "127.0.0.1"


def test_failsafe_nonlocal_without_auth_raises():
    with pytest.raises(RuntimeError):
        load_settings({"STAFF_PORTAL_BIND": "0.0.0.0"})  # auth off


def test_explicit_bind_allowed_with_auth():
    s = load_settings({"STAFF_PORTAL_USER": "u", "STAFF_PORTAL_PASS": "p",
                       "STAFF_PORTAL_BIND": "0.0.0.0"})
    assert s.bind_host == "0.0.0.0"
