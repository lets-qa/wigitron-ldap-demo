#!/bin/bash
#
# Idempotent account hardening for the Wigitron test directory.
#
# Safe to re-run. Run from the host (like seed_directory.sh); it shells into the
# samba-dc container for each samba-tool call. Set CONTAINER to override the name.
#
#   ./harden_accounts.sh
#
# What it does:
#   1. Disables the built-in Guest account.
#   2. Disables domain-wide password aging (--max-pwd-age=0) so nothing expires.
#   3. Clears expiry and exempts every real account (Administrator + testuser*)
#      from aging. Built-in Guest and krbtgt are deliberately left alone.
#   4. Verifies the end state instead of trusting that the commands ran clean.

set -u
CONTAINER="${CONTAINER:-samba-dc}"
dc() { docker exec "$CONTAINER" samba-tool "$@"; }

echo "== 1. Disabling Guest =="
dc user disable Guest && echo "   Guest disabled."

echo "== 2. Disabling domain password aging =="
dc domain passwordsettings set --max-pwd-age=0

echo "== 3. Clearing expiry on real accounts (skipping Guest/krbtgt) =="
# Build the target list: Administrator + every testuser*. krbtgt and Guest are
# built-ins whose credentials are not human-managed, so they are excluded.
mapfile -t USERS < <(dc user list | tr -d '\r' | grep '^testuser' | sort -u)
for u in Administrator "${USERS[@]}"; do
  if dc user setexpiry "$u" --noexpiry >/dev/null 2>&1; then
    echo "   no-expiry set: $u"
  else
    echo "   !! FAILED to set expiry on: $u"
  fi
done

echo "== 4. Verification =="
echo "-- Guest account flags (expect a 'D' = disabled):"
dc user show Guest | grep -i 'account flags' || echo "   (could not read Guest flags)"

echo "-- Domain max password age (expect 0 / unlimited):"
dc domain passwordsettings show | grep -i 'maximum password age'

echo "-- Per-user expiry spot check:"
for u in Administrator "${USERS[@]}"; do
  exp=$(dc user show "$u" | tr -d '\r' | grep -i 'accountExpires' | head -1)
  printf "   %-16s %s\n" "$u" "${exp:-<no accountExpires field>}"
done

echo "-- Account count: ${#USERS[@]} testuser* found (expected 20)."
if [ "${#USERS[@]}" -ne 20 ]; then
  echo "   !! Warning: not 20 testusers — seed_directory.sh may not have fully run."
fi

echo "Done."
