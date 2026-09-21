# Gravity Forms Submission Monitor

Server-level watchdog: if a WordPress site has received **zero Gravity Forms
submissions in the last N hours**, it posts an alert to Slack. Runs from
system cron, not WP-Cron, so it keeps working even when the site itself is
returning 500/503 errors (the exact scenario that prompted this).

## Install

Once this repo is pushed to GitHub (see "Publishing this repo" below),
installing on any server is:

```bash
curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/gf-submission-monitor/main/install.sh -o install.sh
sudo bash install.sh
```

Download-then-run, not `curl | sudo bash` piped directly — piping into
`sudo` can detach the controlling terminal depending on the server's sudo
config (`use_pty` and similar), even in a completely normal SSH session,
which breaks the interactive prompts below. Two commands instead of one,
but it's the reliable way to get real input to `sudo`.

That command:

1. Clones this repo into `/opt/gf-monitor` (or pulls the latest if it's
   already installed there).
2. Hands off to `setup.sh`, which asks whether WordPress runs directly on
   the server or inside Docker, then the relevant follow-up questions
   (Slack webhook URL, WordPress path, file-owning/container user,
   container name if Docker, lookback window, alert cooldown), and writes
   them to `.env`.
3. Offers to send a Slack test message immediately.
4. Runs the real check once so you can see it work.
5. Offers to install the cron job (every 15 minutes) automatically, as the
   right user for the mode (see below).

Re-running the same command later (e.g. to bump the lookback window)
pulls the latest code and re-runs setup — it'll ask before overwriting an
existing `.env`.

## Two deploy modes

- **host** — WordPress and wp-cli run directly on the server. The check
  runs as `sudo -u $WP_USER wp eval ...`, and the cron job runs as that
  same file-owning user (e.g. `www-data`).
- **docker** — WordPress runs in a container. The check runs as
  `docker exec -u $WP_USER $DOCKER_CONTAINER wp eval ...` — the PHP is
  passed as an inline string, so nothing needs to be copied into the
  container. Because `docker exec` itself needs permission (root, or
  membership in the `docker` group), the cron job runs as a separate
  `CRON_USER` (defaults to `root`) rather than the in-container user.

`setup.sh` asks which mode applies and, for Docker, lists running
containers (`docker ps`) before asking which one has wp-cli available.

## Repo layout

```
install.sh                    one-command entry point (clone/update + hand off to setup.sh)
setup.sh                      interactive configurator (writes .env, tests Slack, installs cron)
bin/check-gf-submissions.sh   the actual check, run by cron (handles both deploy modes)
.env.example                  reference list of every config value, for manual editing
.gitignore                    keeps .env, state/, logs/ out of git
```

## Requirements per server

- host mode: WP-CLI installed and working (`wp --info`)
- docker mode: a running container with wp-cli available (`docker exec <container> wp --info`), and `docker` usable by whichever user runs the cron job
- `git` and `curl`
- A Slack Incoming Webhook URL for the alert channel
  (Slack → your workspace → search "Incoming Webhooks" → add to channel)

## Manual test / re-test

```bash
sudo /opt/gf-monitor/bin/check-gf-submissions.sh --test-slack
sudo /opt/gf-monitor/bin/check-gf-submissions.sh          # real check, once
```

## Publishing this repo

This repo is set up as **public** on GitHub (`BeckerMediaNet/gf-submission-monitor`) —
deliberate, not a default: nothing sensitive lives in the code. Every
per-site secret (Slack webhook URL, WP path, etc.) is written to a local
`.env` by `setup.sh` on each server and is `.gitignore`'d, never committed.
That's what makes the plain curl-pipe-bash command above work with zero
auth setup on any server.

I can't push to GitHub on your behalf — no credentials or push access
from this session. The remote is already configured in this folder
(`origin` → `https://github.com/BeckerMediaNet/gf-submission-monitor.git`),
so from your machine it's just:

```bash
cd /Users/mikeh/Sites/LVL/gf-submission-monitor
git add .
git commit -m "Gravity Forms submission monitor"
git push -u origin main
```

If the repo doesn't exist on GitHub yet, create it first (as **public**)
at github.com/organizations/BeckerMediaNet/repositories/new, or via
`gh repo create BeckerMediaNet/gf-submission-monitor --public --source=. --push`.

## Notes / things worth deciding per site

- **24-hour window is a default, not a law.** A low-traffic site can go
  24 hours with zero submissions for entirely normal reasons. Tune
  `LOOKBACK_HOURS` per site during setup, or don't enable this on sites
  where that's expected.
- **`ALERT_COOLDOWN_HOURS`** stops the same alert firing every 15 minutes —
  it re-alerts only after the cooldown, and sends one recovery message when
  submissions resume.
- This checks Gravity Forms entries specifically, which is a good proxy for
  "the whole stack (DB, PHP-FPM, plugin) actually works," not just "nginx
  returns a 200" — that's why it catches things uptime checks on the
  homepage can miss.
