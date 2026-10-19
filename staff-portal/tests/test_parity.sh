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

[ "$fail" -eq 0 ] && echo "PARITY OK" || { echo "PARITY FAILED"; exit 1; }
