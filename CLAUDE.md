# Gaia Digital Agency — Infrastructure Monitor

Static GitHub Pages dashboard showing the latest health snapshot for Gaia's server fleet.

- **Live URL:** https://gaia-digital-agency.github.io/infara_monitor/
- **Remote:** `git@github.com-net1io:Gaia-Digital-Agency/infara_monitor.git`
- **Operator:** ai@gaiada.com (SSH keys to the fleet live on the operator's Mac)

## Hosts

The dashboard covers five SSH aliases, resolved via the operator's `~/.ssh/config`:

- `gda-ce01`
- `gda-ai01`
- `gda-s01`
- `hostinger-vps`
- `hostinger-wp`

## Repo layout

```
infara_monitor/
├── index.html           # Dashboard — static, zero JS deps, reads data/health.json
├── data/health.json     # Latest snapshot, overwritten each refresh
├── scripts/refresh.sh   # SSH → build health.json → git commit → git push
├── .nojekyll            # Tell GH Pages not to run Jekyll
├── .claude/             # Claude Code project settings
└── CLAUDE.md            # (this file)
```

## Refresh workflow — "provide server health"

The refresh runs on the operator's Mac (the only host with SSH access to the fleet):

```bash
cd ~/Downloads/gaiada_infra_monitor
./scripts/refresh.sh
```

The script SSHes to each host in parallel with a short `ConnectTimeout`, captures uptime, load, CPU, memory, disk, kernel, and OS in a single round trip per host, writes `data/health.json` atomically, then commits with a timestamped message and pushes to `main`. GitHub Pages publishes the new snapshot within ~60s.

When a Claude session is asked to "provide server health":
1. Remind the operator to run `./scripts/refresh.sh` (Claude's sandbox cannot SSH to the fleet or push to GitHub — no access to the operator's keys).
2. Once the push lands, read `data/health.json` and summarize: per-host status, anything yellow/red, and the live URL.

## Status rollup (per host)

- **green** — reachable AND load1 < 2.0 AND mem_used_pct < 80 AND disk_used_pct < 85
- **yellow** — any metric in warning band (load 2–4, mem 80–90%, disk 85–95%)
- **red** — unreachable OR any metric past the yellow band

## Conventions

- Snapshot commits: `health: snapshot <ISO-8601 UTC>`
- Code commits: conventional prefix (`feat:`, `fix:`, `chore:`)
- No secrets in the repo. If v2 moves the refresh to GitHub Actions, SSH keys go in repo secrets, not committed.
- The `github.com-net1io` host alias in the git remote points the operator's SSH config at the right key for the `net1io` GitHub identity — don't "fix" it to plain `github.com`.
