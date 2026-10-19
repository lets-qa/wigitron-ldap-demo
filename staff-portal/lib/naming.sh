# Shell mirror of app/naming.py hashing/naming. Requires sha256sum or shasum.
_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-64
  else printf '%s' "$1" | shasum -a 256 | cut -c1-64; fi
}
normalize_fqdn() {
  local v; v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//;s/\.$//')"
  case "$v" in *.*) printf '%s' "$v" ;; *) echo "bad fqdn: $1" >&2; return 1 ;; esac
}
hash4() { _sha256_hex "$(normalize_fqdn "$1")" | cut -c1-4; }
sam() { printf '%s_%s' "$1" "$(hash4 "$2")"; }
group_name() { printf '%s_%s' "$1" "$(hash4 "$2")"; }
