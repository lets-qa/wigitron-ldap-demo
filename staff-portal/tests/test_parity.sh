#!/bin/bash
# Asserts the shell mirrors match the authoritative Python for many N/FQDNs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/allocate.sh"
source "$HERE/../lib/naming.sh"
BK="$HERE/../backend"
PYTHON="${PYTHON:-/tmp/sap-venv/bin/python}"
fail=0

for n in 1 2 3 4 20 50 101; do
  for g in All_Company Dev_Team QA_Team Support_Team Marketing_Team; do
    py=$(cd "$BK" && "$PYTHON" -c "from app.allocate import allocate; print(' '.join(map(str, allocate($n)['$g'])))")
    sh=$(alloc_group "$g" "$n")
    if [ "$py" != "$sh" ]; then echo "MISMATCH alloc $g n=$n: py[$py] sh[$sh]"; fail=1; fi
  done
done

for f in orange.rmorse.com rmorse.com a.b.co; do
  py=$(cd "$BK" && "$PYTHON" -c "from app.naming import hash4; print(hash4('$f'))")
  sh=$(hash4 "$f")
  if [ "$py" != "$sh" ]; then echo "MISMATCH hash4 $f: py[$py] sh[$sh]"; fail=1; fi
done

# Regression: seed_ou.sh must name users via the shared hash suffix.
SEED_SAM=$(SEED_DRYRUN=1 bash "$HERE/../../seed_ou.sh" print-sam testuser1 orange.rmorse.com 2>/dev/null)
PY_SAM=$(cd "$BK" && "$PYTHON" -c "from app.naming import sam; print(sam('testuser1','orange.rmorse.com'))")
if [ "$SEED_SAM" != "$PY_SAM" ]; then echo "MISMATCH seed_ou sam: [$SEED_SAM] vs [$PY_SAM]"; fail=1; fi

# Regression: mail/UPN must be the clean email at the FQDN (hash only in sAM).
SEED_MAIL=$(bash "$HERE/../../seed_ou.sh" print-mail testuser1 orange.rmorse.com 2>/dev/null)
if [ "$SEED_MAIL" != "testuser1@orange.rmorse.com" ]; then echo "MISMATCH seed_ou mail: [$SEED_MAIL]"; fail=1; fi

# FQDN -> OU DN mapping must match the Python app/naming.ou_path (CLI == API).
for f in orange.rmorse.com acme.test a.b.c.com; do
  sh=$(ou_path_leaf "$f" "dc=wigitron,dc=com")
  py=$(cd "$BK" && "$PYTHON" -c "from app.naming import ou_path; print(ou_path('$f','dc=wigitron,dc=com')[-1])")
  if [ "$sh" != "$py" ]; then echo "MISMATCH ou_path $f: sh[$sh] py[$py]"; fail=1; fi
done

[ "$fail" -eq 0 ] && echo "PARITY OK" || { echo "PARITY FAILED"; exit 1; }
