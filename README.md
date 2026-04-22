# Gaia Digital Agency — Infrastructure Monitor

Static GitHub Pages dashboard that shows the latest health snapshot for Gaia's five-server fleet. Refreshed on demand — either from the operator's Mac or via a GitHub Actions workflow.

- **Live dashboard:** https://gaia-digital-agency.github.io/infara_monitor/
- **Snapshot source:** [`data/health.json`](./data/health.json) (overwritten each refresh)

## Fleet

Five SSH aliases (resolved via `~/.ssh/config` locally and via repo secrets in CI):

| Alias | Role |
| --- | --- |
| `gda-ce01` | Gaia compute / edge node 01 |
| `gda-ai01` | Gaia AI node 01 |
| `gda-s01` | Gaia services node 01 |
| `hostinger-vps` | Hostinger VPS |
| `hostinger-wp` | Hostinger WordPress box |

## Repo layout

```
infara_monitor/
├── index.html                     # Dashboard — static, inline CSS, no deps
├── data/health.json               # Latest snapshot (overwritten each refresh)
├── scripts/refresh.sh             # SSH → build health.json → commit → push
├── .github/workflows/health.yml   # Manual-trigger workflow (same script, in CI)
├── .nojekyll                      # Skip Jekyll on GitHub Pages
├── .claude/                       # Claude Code project settings
└── CLAUDE.md                      # Project context for Claude sessions
```

## First-time setup

### 1. Push the scaffold

The repo exists on GitHub but is empty. From the operator's Mac:

```bash
cd ~/Downloads/gaiada_infra_monitor
git init
git branch -M main
git remote add origin git@github.com-net1io:Gaia-Digital-Agency/infara_monitor.git
git add .
git commit -m "feat: initial scaffold (dashboard, refresh script, health workflow)"
git push -u origin main
```

> The `github.com-net1io` host alias is intentional — it points SSH at the right key for the `net1io` GitHub identity in the operator's `~/.ssh/config`. Don't "fix" it to plain `github.com`.

### 2. Enable GitHub Pages

On the GitHub repo: **Settings → Pages → Source: `Deploy from a branch` → Branch: `main` / `(root)`**. Save. Within a minute or so the dashboard is live at the URL above.

### 3. Configure secrets for the CI refresh

Three repo secrets drive the Actions workflow (**Settings → Secrets and variables → Actions → New repository secret**):

| Secret | Contents |
| --- | --- |
| `SSH_PRIVATE_KEY` | The private key authorized on all five hosts. Paste the full key including the `-----BEGIN/END-----` lines. |
| `SSH_CONFIG` | Host blocks for the five aliases from the operator's `~/.ssh/config`, **with `IdentityFile` rewritten to `~/.ssh/id_ed25519`** so it matches where CI writes the key. |
| `SSH_KNOWN_HOSTS` | Output of `ssh-keyscan -H <real-hostname-1> <real-hostname-2> …` for all five hosts (use the real `HostName` values from the config, not the aliases). |

Example `SSH_CONFIG`:

```
Host gda-ce01
  HostName ce01.gaiada.example
  User ops
  IdentityFile ~/.ssh/id_ed25519
Host gda-ai01
  HostName ai01.gaiada.example
  User ops
  IdentityFile ~/.ssh/id_ed25519
# …and so on for the remaining three hosts
```

Generating `SSH_KNOWN_HOSTS`:

```bash
ssh-keyscan -H ce01.gaiada.example ai01.gaiada.example s01.gaiada.example \
            <hostinger-vps-real> <hostinger-wp-real>
```

Paste the full output into the secret.

## Refreshing the dashboard

### Locally (operator's Mac)

```bash
cd ~/Downloads/gaiada_infra_monitor
./scripts/refresh.sh
```

The script SSHes to each host in parallel with an 8-second connect timeout, gathers uptime / load / CPU / memory / disk / kernel / OS in one round trip per host, writes `data/health.json`, commits with `health: snapshot <ISO-UTC>`, and pushes to `main`. GitHub Pages republishes within ~60 seconds.

### Via GitHub Actions

From the Actions tab, open the **health** workflow and click **Run workflow** → **Run** — or from the Mac terminal:

```bash
gh workflow run health.yml
```

The workflow reconstructs `~/.ssh/{config,id_ed25519,known_hosts}` from the three secrets above, runs the same `scripts/refresh.sh`, and lets the script commit/push using the workflow's `GITHUB_TOKEN`. Keys are scrubbed from the runner on exit.

## Status thresholds

Per-host rollup:

- **green** — reachable AND `load1 < 2.0` AND `mem_used_pct < 80` AND `disk_used_pct < 85`
- **yellow** — any metric in the warning band (`load 2–4`, `mem 80–90%`, `disk 85–95%`)
- **red** — unreachable OR any metric past the yellow band

The header badge on the dashboard rolls up to the worst per-host status.

## Requirements

- **Runner** (Mac or CI): `bash`, `ssh`, `jq`, `git`, `awk`, `date`.
  - macOS: `brew install jq` if not already installed.
  - Ubuntu CI: `jq` is installed by the workflow.
- **Remote hosts**: Linux with `bash`, `/proc`, `free`, `df`, `uname`. Standard Ubuntu/Debian.

## Conventions

- Snapshot commits: `health: snapshot <ISO-8601 UTC>` (written by `refresh.sh`).
- Code commits: conventional prefix — `feat:`, `fix:`, `chore:`.
- **No secrets in the repo.** SSH private keys live on the Mac and as repo secrets for CI — nowhere else.
