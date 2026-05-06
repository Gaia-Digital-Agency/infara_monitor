# Gaia Digital Agency — Infrastructure Monitor

Static GitHub Pages dashboard showing the latest health snapshot for Gaia's server fleet.

- **Live URL:** https://gaia-digital-agency.github.io/infara_monitor/
- **Remote:** `git@github.com-net1io:Gaia-Digital-Agency/infara_monitor.git`
- **Local path:** `~/Documents/gaiada_tools/gaiada_infra_monitor`
- **Operator:** ai@gaiada.com (SSH keys to the fleet live on the operator's Mac)

## Hosts

Six SSH aliases, resolved via the operator's `~/.ssh/config` locally and via repo secrets in CI:

- `gda-ce01` — Gaia compute / edge node (VPS)
- `gda-pn01` — Gaia node 01 (VPS, added 2026-05-06)
- `gda-ai01` — Gaia AI node (VPS)
- `gda-s01` — Gaia services node (VPS)
- `hostinger-wp` — Hostinger WordPress box (kind: `shared` — graded on disk + reachability only; load/mem report the host machine, not our tenant slice)
- `hostinger-vps` — Hostinger VPS

Dashboard layout (3-col desktop grid):
- Top row: `gda-ce01` · `gda-pn01` · `gda-ai01`
- Bottom row: `gda-s01` · `hostinger-wp` · `hostinger-vps`

## Repo layout

```
infara_monitor/
├── index.html                       # Dashboard — static, inline CSS, no deps
├── data/health.json                 # Latest snapshot (overwritten each refresh)
├── scripts/refresh.sh               # SSH → build health.json → commit → push
├── scripts/grade-snapshot.sh        # Grades a snapshot; emits alert markdown
├── scripts/reconcile-alert-issue.sh # Opens/updates/closes the rolling alert issue
├── scripts/gen-secrets.sh           # Helper to produce CI SSH secrets
├── .github/workflows/health.yml     # Manual + cron CI refresh, runs the same script
├── .nojekyll                        # Skip Jekyll on GitHub Pages
├── .claude/                         # Claude Code project settings
└── CLAUDE.md                        # (this file)
```

## Refresh workflow — "provide server health"

Two ways to refresh; both produce the same `data/health.json` and the same snapshot commit.

**Local (operator's Mac, fastest):**

```bash
cd ~/Documents/gaiada_tools/gaiada_infra_monitor
./scripts/refresh.sh
```

**CI (GitHub Actions):** Run the `health` workflow manually (`gh workflow run health.yml`) or let the daily 04:00 Asia/Singapore cron fire it. The workflow rebuilds `~/.ssh/{config,id_ed25519_gaia,known_hosts}` from three repo secrets (`SSH_CONFIG`, `SSH_KNOWN_HOSTS`, `SSH_PRIVATE_KEY`) and runs the same `scripts/refresh.sh`.

Either path: SSH to each host in parallel with short `ConnectTimeout`, capture uptime/load/CPU/memory/disk/kernel/OS in one round trip, write `data/health.json` atomically, commit as `health: snapshot <ISO-UTC>`, push to `main`. GitHub Pages publishes within ~60s.

When a Claude session is asked to "provide server health":
1. Remind the operator to run `./scripts/refresh.sh` (Claude's sandbox cannot SSH to the fleet — no access to the operator's keys).
2. Once the push lands, read `data/health.json` and summarize: per-host status, anything yellow/red, and the live URL.

## Status rollup (per host)

- **green** — reachable AND `load1 < 2.0` (core-aware for VPS) AND `mem_used_pct < 80` AND `disk_used_pct < 85`
- **yellow** — any metric in warning band (`load 2–4`, `mem 80–90%`, `disk 85–95%`)
- **red** — unreachable OR any metric past yellow

Shared hosts (`hostinger-wp`) are graded on disk + reachability only. Header badge rolls up to the worst per-host status.

## Alerts

Each workflow run (manual or cron) grades the fresh snapshot and keeps a single rolling GitHub issue in sync with what's broken. Watchers get email from `notifications@github.com` on state changes — not on every cron run. Managed by `scripts/grade-snapshot.sh` + `scripts/reconcile-alert-issue.sh`. Snooze by adding the `health-alert-snoozed` label to the open alert issue.

## Conventions

- Snapshot commits: `health: snapshot <ISO-8601 UTC>` (written by `refresh.sh`)
- Code commits: conventional prefix (`feat:`, `fix:`, `chore:`)
- No secrets in the repo. SSH private keys live on the Mac and as repo secrets for CI — nowhere else.
- The `github.com-net1io` host alias in the git remote points SSH at the `net1io` GitHub identity key in the operator's `~/.ssh/config` — don't "fix" it to plain `github.com`.
