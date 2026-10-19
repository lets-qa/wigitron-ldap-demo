#!/bin/bash
# Launch the staff portal. Bind host is derived from auth env (see backend/app/config.py):
# 127.0.0.1 without auth, 0.0.0.0 with STAFF_PORTAL_USER+PASS; non-loopback without auth fails.
set -eu
PYTHON="${PYTHON:-/tmp/sap-venv/bin/python}"
UVICORN="${UVICORN:-/tmp/sap-venv/bin/uvicorn}"
cd "$(dirname "${BASH_SOURCE[0]}")/backend"
BIND=$("$PYTHON" -c "import os;from app.config import load_settings;print(load_settings(os.environ).bind_host)")
exec "$UVICORN" app.main:app --host "$BIND" --port "${STAFF_PORTAL_PORT:-8099}"
