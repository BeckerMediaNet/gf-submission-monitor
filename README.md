# Gravity Forms Submission Monitor

Server-level watchdog: if a WordPress site has received **zero Gravity Forms
submissions in the last N hours**, it posts an alert to Slack. Runs from
system cron, not WP-Cron, so it keeps working even when the site itself is
returning 500/503 errors (the exact scenario that prompted this).

## One-command install

Once this repo is pushed to GitHub (see "Publishing this repo" below),
installing on any server is:

```bash
curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/gf-submission-monitor/main/install.sh | sudo bash
```

That command:

1. Clones this repo into `/opt/gf-monitor` (or pulls the latest if it's
   already installed there).
2. Hands off to `setup.sh`, which interactively asks for the Slack webhook
   URL, WordPress path, file-owning user, lookback window, and alert
   cooldown, and writes them to `.env`.
3. Offers to send a Slack test message immediately.
4. Runs the real check once so you can see it work.
5. Offers to install the cron job (every 15 minutes, as the WordPress
   file-owning user) automatically.

Re-running the same command later (e.g. to bump the lookback window)
pulls the latest code and re-runs setup — it'll ask before overwriting an
existing `.env`.

## Repo layout

```
install.sh              one-command entry point (clone/update + hand off to setup.sh)
setup.sh                interactive configurator (writes .env, tests Slack, installs cron)
bin/check-gf-submissions.sh   the actual check, run by cron
share/gf-count.php      counts Gravity Forms entries via GFAPI (run through `wp eval-file`)
.env.example            reference list of every config value, for manual editing
.gitignore              keeps .env, state/, logs/ out of git
```

## Requirements per server

- WP-CLI installed and working (`wp --info`)
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
