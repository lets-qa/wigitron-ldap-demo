"""Environment-driven settings with auth/bind coupling and a fail-safe."""
from dataclasses import dataclass
from typing import Mapping, Optional

_LOOPBACK = {"127.0.0.1", "localhost", "::1"}


@dataclass
class Settings:
    auth_user: Optional[str]
    auth_pass: Optional[str]
    bind_host: str
    container: str
    base_dn: str
    max_users: int


def auth_enabled(s: "Settings") -> bool:
    return bool(s.auth_user) and bool(s.auth_pass)


def load_settings(env: Mapping) -> Settings:
    user = env.get("STAFF_PORTAL_USER") or None
    pw = env.get("STAFF_PORTAL_PASS") or None
    has_auth = bool(user) and bool(pw)
    explicit_bind = env.get("STAFF_PORTAL_BIND") or None
    bind = explicit_bind or ("0.0.0.0" if has_auth else "127.0.0.1")
    if not has_auth and bind not in _LOOPBACK:
        raise RuntimeError(
            f"Refusing to bind non-loopback host {bind!r} without auth. "
            "Set STAFF_PORTAL_USER and STAFF_PORTAL_PASS to expose externally."
        )
    return Settings(
        auth_user=user, auth_pass=pw, bind_host=bind,
        container=env.get("STAFF_PORTAL_CONTAINER", "samba-dc"),
        base_dn=env.get("STAFF_PORTAL_BASE_DN", "dc=wigitron,dc=com"),
        max_users=int(env.get("STAFF_PORTAL_MAX_USERS", "500")),
    )
