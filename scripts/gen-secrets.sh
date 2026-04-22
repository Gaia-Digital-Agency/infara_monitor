#!/usr/bin/env bash
# scripts/gen-secrets.sh
#
# Run this on the operator's Mac. It prints the values to paste into the three
# GitHub repo secrets the health workflow needs, plus a hint about which
# private key(s) your config uses so you know what to put in SSH_PRIVATE_KEY.
#
# This script NEVER reads or prints the private key itself — copy that into
# the SSH_PRIVATE_KEY secret separately (see the end of this script's output).
#
# Usage:
#   ./scripts/gen-secrets.sh              # prints everything to stdout
#   ./scripts/gen-secrets.sh --config     # only the SSH_CONFIG value
#   ./scripts/gen-secrets.sh --hosts      # only the SSH_KNOWN_HOSTS value
#   ./scripts/gen-secrets.sh --identity   # only the identity-file diagnostic

set -euo pipefail

HOSTS=(gda-ce01 gda-ai01 gda-s01 hostinger-vps hostinger-wp)
MODE="${1:-all}"

for t in ssh ssh-keygen ssh-keyscan awk sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: '$t' not found" >&2; exit 1; }
done

# Use ssh -G to resolve effective settings per alias.
resolve() {
  local alias="$1" field="$2"
  ssh -G "$alias" 2>/dev/null | awk -v f="$field" 'tolower($1)==f {print $2; exit}'
}

# ----------------------------------------------------------------------
# SSH_CONFIG — reconstructed Host blocks, IdentityFile pinned to the
# path the CI workflow writes the key to.
# ----------------------------------------------------------------------
gen_config() {
  for alias in "${HOSTS[@]}"; do
    local host port user
    host=$(resolve "$alias" hostname)
    port=$(resolve "$alias" port)
    user=$(resolve "$alias" user)
    if [ -z "$host" ]; then
      echo "# WARNING: no HostName resolved for alias '$alias' — check ~/.ssh/config" >&2
      continue
    fi
    printf 'Host %s\n'              "$alias"
    printf '  HostName %s\n'        "$host"
    [ -n "$user" ] && printf '  User %s\n'  "$user"
    [ -n "$port" ] && [ "$port" != "22" ] && printf '  Port %s\n' "$port"
    printf '  IdentityFile ~/.ssh/id_ed25519_gaia\n'
    printf '  IdentitiesOnly yes\n'
    printf '\n'
  done
}

# ----------------------------------------------------------------------
# SSH_KNOWN_HOSTS — ssh-keyscan against the real hostnames (not aliases),
# honouring per-host port.
# ----------------------------------------------------------------------
gen_known_hosts() {
  for alias in "${HOSTS[@]}"; do
    local host port
    host=$(resolve "$alias" hostname)
    port=$(resolve "$alias" port)
    [ -n "$host" ] || continue
    ssh-keyscan -H -T 5 -p "${port:-22}" "$host" 2>/dev/null
  done
}

# ----------------------------------------------------------------------
# Identity-file diagnostic — tells you which private key file(s) your
# config uses across the five aliases, so you know what goes into
# SSH_PRIVATE_KEY.
# ----------------------------------------------------------------------
gen_identity() {
  local -A seen=()
  for alias in "${HOSTS[@]}"; do
    # ssh -G can emit multiple identityfile lines; take the first.
    local id
    id=$(ssh -G "$alias" 2>/dev/null | awk 'tolower($1)=="identityfile"{print $2; exit}')
    # expand ~
    id="${id/#\~/$HOME}"
    printf '  %-16s → %s\n' "$alias" "${id:-<unset>}"
    [ -n "$id" ] && seen["$id"]=1
  done
  echo
  echo "Distinct identity files in use:"
  for k in "${!seen[@]}"; do echo "  $k"; done
  if [ "${#seen[@]}" -gt 1 ]; then
    echo
    echo "⚠  More than one key is in use across the five hosts." >&2
    echo "   The CI workflow assumes a SINGLE key at ~/.ssh/id_ed25519_gaia." >&2
    echo "   Either (a) consolidate to one key authorized on all five hosts," >&2
    echo "   or (b) adjust .github/workflows/health.yml to write multiple keys" >&2
    echo "   and keep per-host IdentityFile entries in SSH_CONFIG." >&2
  fi
}

banner() { printf '\n========== %s ==========\n' "$1"; }

case "$MODE" in
  --config)   gen_config ;;
  --hosts)    gen_known_hosts ;;
  --identity) gen_identity ;;
  all|*)
    banner "SSH_CONFIG (paste into GitHub repo secret SSH_CONFIG)"
    gen_config
    banner "SSH_KNOWN_HOSTS (paste into GitHub repo secret SSH_KNOWN_HOSTS)"
    gen_known_hosts
    banner "Identity files — informational only"
    gen_identity
    cat <<'EOF'

========== SSH_PRIVATE_KEY ==========
For the SSH_PRIVATE_KEY secret, copy the contents of the identity file above
directly into the GitHub UI. Do NOT print it here; use a secure path:

  pbcopy < ~/.ssh/id_ed25519_gaia   # copies to clipboard, then paste into GitHub
  # or
  cat ~/.ssh/id_ed25519_gaia | less # inspect, then paste manually

Make sure the secret value includes the full
    -----BEGIN OPENSSH PRIVATE KEY-----
    …
    -----END OPENSSH PRIVATE KEY-----
with no leading/trailing whitespace.
EOF
    ;;
esac
