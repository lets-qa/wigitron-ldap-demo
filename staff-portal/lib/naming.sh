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

# Mirror of app/naming.py ou_path: every FQDN label except the TLD becomes a
# nested OU, right-to-left. ou_path_leaf <fqdn> <base_dn> echoes the full leaf
# DN (e.g. orange.rmorse.com -> OU=orange,OU=rmorse,dc=wigitron,dc=com).
ou_path_leaf() {
  local fqdn base dn suffix org_labels label
  fqdn="$(normalize_fqdn "$1")" || return 1
  base="$2"
  suffix="$base"
  dn="$base"
  # org labels = everything except the TLD (last label); nest right-to-left.
  org_labels="${fqdn%.*}"          # strip the final .tld
  # Walk labels left-to-right building suffix, so the final dn is the leaf.
  local rest="$org_labels"
  # Reverse-nest: process rightmost org label first by repeatedly taking the
  # last "."-separated field.
  while [ -n "$rest" ]; do
    case "$rest" in
      *.*) label="${rest##*.}"; rest="${rest%.*}" ;;
      *)   label="$rest"; rest="" ;;
    esac
    dn="OU=${label},${suffix}"
    suffix="$dn"
  done
  printf '%s' "$dn"
}

# ou_path_relative <fqdn> <base_dn>: the leaf OU path WITHOUT the base DN
# suffix, for samba-tool --userou/--groupou (which append the domain again).
# orange.rmorse.com -> OU=orange,OU=rmorse
ou_path_relative() {
  local leaf base
  leaf="$(ou_path_leaf "$1" "$2")" || return 1
  base="$2"
  printf '%s' "${leaf%,$base}"
}
