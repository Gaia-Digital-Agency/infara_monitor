#!/usr/bin/env bash
# scripts/refresh.sh
#
# Probe the 5 Gaia hosts over SSH in parallel, build data/health.json,
# commit, and push to origin/main.
#
# Runs identically:
#   • locally on the operator's Mac  — uses ~/.ssh/config, ~/.ssh/id_*, agent
#   • inside GitHub Actions          — the workflow writes matching
#                                      ~/.ssh/{config,id_ed25519,known_hosts}
#                                      from repo secrets before calling this.
#
# Requirements on the runner: bash, ssh, jq, git, awk, date.
# Requirements on the remote hosts: bash, /proc, free, df, uname (Linux).

set -euo pipefail

HOSTS=(gda-ce01 gda-ai01 gda-s01 hostinger-vps hostinger-wp)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$REPO_ROOT/data"
OUT_FILE="$DATA_DIR/health.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for t in ssh jq git awk date; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "ERROR: required tool '$t' not found in PATH" >&2
    exit 1
  }
done

mkdir -p "$DATA_DIR"

# ----------------------------------------------------------------------
# Remote probe — one SSH round trip per host.
# Outputs KEY|||VALUE lines; parsed locally into JSON by jq.
# ----------------------------------------------------------------------
REMOTE_SCRIPT=$(cat <<'REMOTE'
set -eu

HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)
UPTIME_VAL=$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/^[^,]*up //;s/,  *[0-9]* user.*//' || echo unknown)
KERNEL_VAL=$(uname -r 2>/dev/null || echo unknown)

OS_VAL="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_VAL="${PRETTY_NAME:-${NAME:-unknown}}"
fi

# Load averages from /proc/loadavg
read LOAD1 LOAD5 LOAD15 _REST < /proc/loadavg

# CPU % — two samples of /proc/stat 0.4s apart, compute non-idle fraction.
# Use command substitution (not process substitution) so this works on
# restricted shared-hosting shells that don't mount /dev/fd.
cpu_sample() {
  awk '/^cpu / {
    total = $2+$3+$4+$5+$6+$7+$8+$9
    idle  = $5+$6
    print total, idle
  }' /proc/stat
}
set -- $(cpu_sample); T1=$1; I1=$2
sleep 0.4
set -- $(cpu_sample); T2=$1; I2=$2
DT=$((T2 - T1))
DI=$((I2 - I1))
if [ "$DT" -gt 0 ]; then
  CPU_PCT=$(awk -v dt="$DT" -v di="$DI" 'BEGIN{printf "%.1f", (1 - di/dt) * 100}')
else
  CPU_PCT="0.0"
fi

# Memory from /proc/meminfo (used = total - available).
MEM_TOTAL_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL_MB=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
if [ -z "${MEM_AVAIL_MB:-}" ] || [ "$MEM_AVAIL_MB" = "0" ]; then
  # Older kernels without MemAvailable — fall back to MemFree + Buffers + Cached
  MEM_AVAIL_MB=$(awk '/^MemFree:|^Buffers:|^Cached:/ {s+=$2} END{printf "%d", s/1024}' /proc/meminfo)
fi
MEM_USED_MB=$((MEM_TOTAL_MB - MEM_AVAIL_MB))
if [ "$MEM_TOTAL_MB" -gt 0 ]; then
  MEM_PCT=$(awk -v u="$MEM_USED_MB" -v t="$MEM_TOTAL_MB" 'BEGIN{printf "%.1f", u/t*100}')
else
  MEM_PCT="0.0"
fi

# Disk / — use portable 1K blocks from POSIX df.
DISK_LINE=$(df -Pk / | awk 'NR==2')
DISK_TOTAL_GB=$(echo "$DISK_LINE" | awk '{printf "%.1f", $2/1048576}')
DISK_USED_GB=$(echo  "$DISK_LINE" | awk '{printf "%.1f", $3/1048576}')
DISK_PCT=$(echo      "$DISK_LINE" | awk '{gsub("%","",$5); print $5}')

printf 'HOSTNAME|||%s\n'      "$HOSTNAME_VAL"
printf 'UPTIME|||%s\n'        "$UPTIME_VAL"
printf 'KERNEL|||%s\n'        "$KERNEL_VAL"
printf 'OS|||%s\n'            "$OS_VAL"
printf 'LOAD1|||%s\n'         "$LOAD1"
printf 'LOAD5|||%s\n'         "$LOAD5"
printf 'LOAD15|||%s\n'        "$LOAD15"
printf 'CPU_PCT|||%s\n'       "$CPU_PCT"
printf 'MEM_TOTAL_MB|||%s\n'  "$MEM_TOTAL_MB"
printf 'MEM_USED_MB|||%s\n'   "$MEM_USED_MB"
printf 'MEM_PCT|||%s\n'       "$MEM_PCT"
printf 'DISK_TOTAL_GB|||%s\n' "$DISK_TOTAL_GB"
printf 'DISK_USED_GB|||%s\n'  "$DISK_USED_GB"
printf 'DISK_PCT|||%s\n'      "$DISK_PCT"
REMOTE
)

# ----------------------------------------------------------------------
# Per-host probe (called in background, one per alias).
# ----------------------------------------------------------------------
probe_host() {
  local alias="$1"
  local out="$TMP_DIR/$alias.json"
  local log="$TMP_DIR/$alias.log"
  local checked_at
  checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=2 \
        -o StrictHostKeyChecking=accept-new \
        -o LogLevel=ERROR \
        "$alias" "bash -s" <<<"$REMOTE_SCRIPT" >"$log" 2>&1; then
    jq -Rn \
      --arg alias "$alias" \
      --arg checked_at "$checked_at" \
      --rawfile raw "$log" '
        ($raw
          | split("\n")
          | map(select(length > 0) | split("|||"))
          | map(select(length == 2) | {key: .[0], value: .[1]})
          | from_entries) as $kv
        | {
            alias: $alias,
            reachable: true,
            hostname: ($kv.HOSTNAME // null),
            uptime: ($kv.UPTIME // null),
            kernel: ($kv.KERNEL // null),
            os: ($kv.OS // null),
            load1:  (try ($kv.LOAD1  | tonumber) catch null),
            load5:  (try ($kv.LOAD5  | tonumber) catch null),
            load15: (try ($kv.LOAD15 | tonumber) catch null),
            cpu_used_pct:  (try ($kv.CPU_PCT      | tonumber) catch null),
            mem_total_mb:  (try ($kv.MEM_TOTAL_MB | tonumber) catch null),
            mem_used_mb:   (try ($kv.MEM_USED_MB  | tonumber) catch null),
            mem_used_pct:  (try ($kv.MEM_PCT      | tonumber) catch null),
            disk_total_gb: (try ($kv.DISK_TOTAL_GB| tonumber) catch null),
            disk_used_gb:  (try ($kv.DISK_USED_GB | tonumber) catch null),
            disk_used_pct: (try ($kv.DISK_PCT     | tonumber) catch null),
            checked_at: $checked_at,
            ssh_error: null
          }
      ' >"$out"
  else
    local rc=$?
    local err
    err=$(head -c 400 "$log" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    [ -n "$err" ] || err="ssh failed (exit $rc)"
    jq -n \
      --arg alias "$alias" \
      --arg err "$err" \
      --arg checked_at "$checked_at" '
        {
          alias: $alias,
          reachable: false,
          ssh_error: $err,
          checked_at: $checked_at
        }
      ' >"$out"
  fi
}

echo "→ probing ${#HOSTS[@]} hosts in parallel…"
for h in "${HOSTS[@]}"; do
  probe_host "$h" &
done
wait

# ----------------------------------------------------------------------
# Combine per-host JSONs into one snapshot, preserving host order.
# ----------------------------------------------------------------------
ORDER_JSON=$(printf '%s\n' "${HOSTS[@]}" | jq -R . | jq -s .)
HOSTS_JSON=$(jq -s . "$TMP_DIR"/*.json)
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --argjson order    "$ORDER_JSON" \
  --argjson hosts    "$HOSTS_JSON" \
  --arg     generated_at "$GENERATED_AT" '
    ($hosts | map({(.alias): .}) | add) as $by
    | {
        generated_at: $generated_at,
        hosts: [ $order[] | ($by[.] // { alias: ., reachable: false, ssh_error: "no result", checked_at: $generated_at }) ]
      }
  ' >"$TMP_DIR/snapshot.json"

# Atomic install
mv "$TMP_DIR/snapshot.json" "$OUT_FILE"
echo "→ wrote $OUT_FILE"

# ----------------------------------------------------------------------
# Short human-readable summary to stdout.
# ----------------------------------------------------------------------
jq -r '
  .hosts[] |
  if .reachable then
    (if   (.load1 >= 4) or (.mem_used_pct >= 90) or (.disk_used_pct >= 95) then "red"
     elif (.load1 >= 2) or (.mem_used_pct >= 80) or (.disk_used_pct >= 85) then "yellow"
     else "green" end) as $s
    | "  \($s | ascii_upcase | .[0:1]) \(.alias)  load=\(.load1) mem=\(.mem_used_pct)% disk=\(.disk_used_pct)%  [\($s)]"
  else
    "  R \(.alias)  UNREACHABLE: \(.ssh_error)"
  end
' "$OUT_FILE"

# ----------------------------------------------------------------------
# Commit & push — only if health.json actually changed.
# ----------------------------------------------------------------------
cd "$REPO_ROOT"

# Make sure we're in a git repo (skip commit step otherwise, e.g. during first scaffold run).
if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "→ not a git repo yet, skipping commit/push"
  exit 0
fi

if git diff --quiet -- data/health.json 2>/dev/null; then
  echo "→ no change in data/health.json, not committing"
  exit 0
fi

if ! git config user.email >/dev/null 2>&1; then
  git config user.email "ai@gaiada.com"
  git config user.name  "Gaia health bot"
fi

git add data/health.json
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git commit -m "health: snapshot $TS"

echo "→ pushing to origin/main"
git push origin HEAD:main
echo "→ done"
