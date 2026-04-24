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
cd ~/Documents/gaiada_tools/gaiada_infra_monitor
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

Three **repository** secrets drive the Actions workflow (**Settings → Secrets and variables → Actions → New repository secret**). A helper script resolves the first two for you against the operator's live `~/.ssh/config`:

```bash
cd ~/Documents/gaiada_tools/gaiada_infra_monitor
./scripts/gen-secrets.sh
```

It uses `ssh -G <alias>` to print effective config (honouring Includes, Match blocks, etc.), then emits:

| Secret | How it's produced |
| --- | --- |
| `SSH_CONFIG` | The five Host blocks from `~/.ssh/config` — copied verbatim. The CI workflow writes the key to the same path your config references (`~/.ssh/id_ed25519_gaia`), so no rewriting needed. |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan -H -p <port> <real-hostname>` for each of the five hosts. |
| `SSH_PRIVATE_KEY` | The contents of `~/.ssh/id_ed25519_gaia` on the operator's Mac. Copy into the secret manually — e.g. `pbcopy < ~/.ssh/id_ed25519_gaia`, then paste into GitHub. |

If the identity-file diagnostic shows more than one key across the five hosts, either consolidate to a single key authorized on all five, or extend `.github/workflows/health.yml` to materialize multiple keys and keep per-host `IdentityFile` entries in `SSH_CONFIG`.

## Refreshing the dashboard

### Locally (operator's Mac)

This is the fastest way — no CI involved, no secrets plumbing, just one command.

**Prerequisites** (one-time):
- `git`, `ssh`, `jq`, `bash`, `awk`, `date` in `$PATH` (`brew install jq` if `jq` is missing).
- `~/.ssh/config` has the five `Host` aliases and the matching key (`~/.ssh/id_ed25519_gaia`) is authorized on all five boxes. Confirm with:
  ```bash
  for h in gda-ce01 gda-ai01 gda-s01 hostinger-vps hostinger-wp; do
    echo -n "$h: "; ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" 'echo OK $(hostname)' 2>&1 | head -1
  done
  ```
  Every line should start with `OK`. If any host says `Permission denied` or `Connection timed out`, fix SSH first — the refresh can't work around it.
- The repo is cloned and its `origin` remote is writable (your shell can `git push` without prompting).

**Run:**

```bash
cd ~/Documents/gaiada_tools/gaiada_infra_monitor
./scripts/refresh.sh
```

**What you'll see** (typical output, ~5 s):

```
→ probing 5 hosts in parallel…
→ wrote /Users/.../data/health.json
  G gda-ce01  load=1.04 mem=51.2% disk=70%  [green]
  G gda-ai01  load=0.02 mem=48.5% disk=83%  [green]
  G gda-s01  load=1.36 mem=43.5% disk=70%  [green]
  G hostinger-vps  load=1.89 mem=24.3% disk=37%  [green]
  G hostinger-wp  load=47.13 mem=62.8% disk=53%  [green shared]
[main abcd123] health: snapshot 2026-04-22T05:14:11Z
→ pushing to origin/main
→ done
```

The script SSHes to each host in parallel with an 8-second connect timeout, captures uptime / load / CPU / memory / disk / kernel / OS in one round trip per host, writes `data/health.json` atomically, commits with `health: snapshot <ISO-UTC>`, and pushes to `main`. GitHub Pages republishes the dashboard within ~60 seconds — open <https://gaia-digital-agency.github.io/infara_monitor/> and hit **Refresh view** to see the new snapshot.

**Troubleshooting:**

- *`required tool 'jq' not found`* → `brew install jq`.
- *Host shows `UNREACHABLE`* → test `ssh <alias>` by hand. Fix SSH before rerunning.
- *`no change in data/health.json, not committing`* → the snapshot is byte-identical to what's already on disk; nothing to push. Rerun in a few seconds if you expected a change.
- *`git push` fails with auth error* → your `origin` uses an SSH URL (`git@github.com-net1io:…`) that needs the `net1io` GitHub identity; confirm `ssh -T git@github.com-net1io` works.

### Via GitHub Actions

From the Actions tab, open the **health** workflow and click **Run workflow** → **Run** — or from the Mac terminal:

```bash
gh workflow run health.yml
```

The workflow reconstructs `~/.ssh/{config,id_ed25519_gaia,known_hosts}` from the three secrets above, runs the same `scripts/refresh.sh`, and lets the script commit/push using the workflow's `GITHUB_TOKEN`. Keys are scrubbed from the runner on exit.

## Status thresholds

Per-host rollup:

- **green** — reachable AND `load1 < 2.0` AND `mem_used_pct < 80` AND `disk_used_pct < 85`
- **yellow** — any metric in the warning band (`load 2–4`, `mem 80–90%`, `disk 85–95%`)
- **red** — unreachable OR any metric past the yellow band

Hosts tagged `kind: "shared"` in `scripts/refresh.sh` (e.g. `hostinger-wp`) are graded on **disk + reachability only**. Their `/proc/loadavg` and `/proc/meminfo` report the physical host machine, not our tenant slice, so the numbers are meaningful (e.g. 47 load) without being actionable. The dashboard shows those figures with a `shared` badge and a *(host-wide)* note next to memory.

The header badge on the dashboard rolls up to the worst per-host status.

## Alerts

Each workflow run (including the daily 04:00 Asia/Singapore cron) grades the fresh snapshot and keeps a single rolling GitHub issue in sync with what's broken. Watchers get email from `notifications@github.com` on state changes — not on every cron run.

| Scenario | What the workflow does | Email |
| --- | --- | --- |
| All green | Closes the open alert issue (if any) with a ✅ resolution comment | One (on the close comment) |
| New problem | Opens `🚨 Health alert — <summary>`, labels it `health-alert`, @mentions recipients | One (issue opened) |
| Same problem as last run | Edits the issue body in place (new snapshot time/values) | **Silent** |
| Status worsened / new host joined / partial recovery | Edits body + posts a state-change comment | One per state change |
| Full recovery | Closes issue with resolution comment | One |

**To subscribe (receive email):**

1. The workflow @mentions `@azlangaida` and `@gda-gusde` — they get email automatically when opened/commented. Configured in [`health.yml`](.github/workflows/health.yml) under `ALERT_MENTIONS`.
2. For anyone else: visit the repo → **Watch → Custom → Issues** (or **All activity**). Check spam if nothing arrives — the sender is `notifications@github.com`.
3. For mentions to deliver on a **private** repo, the mentioned accounts must be collaborators. On a public repo it's unconditional.

**To snooze** (e.g. during planned maintenance):

Add the label `health-alert-snoozed` to the open alert issue. The workflow will still refresh the body each run but will not post state-change comments while the label is present — so no more email until you remove it. Labels are one-click on the issue sidebar.

**Thresholds** are the same ones the dashboard uses (core-aware for VPS hosts, disk-only for shared), so anything that turns a dashboard card yellow or red will also open/update the alert issue.

**Testing the grader locally** (no GitHub changes, prints what the email would say):

```bash
./scripts/grade-snapshot.sh data/health.json /tmp/alert.md
cat /tmp/alert.md     # empty if all green
```

## Requirements

- **Runner** (Mac or CI): `bash`, `ssh`, `jq`, `git`, `awk`, `date`.
  - macOS: `brew install jq` if not already installed.
  - Ubuntu CI: `jq` is installed by the workflow.
- **Remote hosts**: Linux with `bash`, `/proc`, `free`, `df`, `uname`. Standard Ubuntu/Debian.

## Conventions

- Snapshot commits: `health: snapshot <ISO-8601 UTC>` (written by `refresh.sh`).
- Code commits: conventional prefix — `feat:`, `fix:`, `chore:`.
- **No secrets in the repo.** SSH private keys live on the Mac and as repo secrets for CI — nowhere else.
