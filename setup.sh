#!/usr/bin/env bash
#
# setup.sh — interactive configurator for the Gravity Forms submission
# monitor. Run directly (from inside the cloned repo) or via install.sh,
# which clones the repo and calls this automatically.
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
CHECK_SCRIPT="$ROOT_DIR/bin/check-gf-submissions.sh"

echo "=================================================================="
echo " Gravity Forms Submission Monitor — setup"
echo " Installing into: $ROOT_DIR"
echo "=================================================================="
echo

if [[ -f "$ENV_FILE" ]]; then
  echo "A .env already exists at $ENV_FILE."
  read -rp "Overwrite it with new answers? [y/N]: " OVERWRITE
  if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
    echo "Keeping existing .env. Re-run with that answer set to 'y' to redo it."
    SKIP_ENV=true
  fi
fi

if [[ "${SKIP_ENV:-false}" != true ]]; then
  read -rp "Site label (e.g. 'Acme Co - acme.com'): " SITE_LABEL
  read -rp "WordPress path (folder with wp-config.php) [/var/www/html]: " WP_PATH
  WP_PATH="${WP_PATH:-/var/www/html}"

  read -rp "Linux user that owns the WordPress files [www-data]: " WP_USER
  WP_USER="${WP_USER:-www-data}"

  DEFAULT_WP_BIN="$(command -v wp || true)"
  read -rp "wp-cli binary path [${DEFAULT_WP_BIN:-wp}]: " WP_CLI_BIN
  WP_CLI_BIN="${WP_CLI_BIN:-${DEFAULT_WP_BIN:-wp}}"

  while [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; do
    read -rp "Slack Incoming Webhook URL: " SLACK_WEBHOOK_URL
  done

  read -rp "Lookback window in hours [24]: " LOOKBACK_HOURS
  LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"

  read -rp "Alert cooldown in hours, to avoid repeat alerts [6]: " ALERT_COOLDOWN_HOURS
  ALERT_COOLDOWN_HOURS="${ALERT_COOLDOWN_HOURS:-6}"

  read -rp "Specific Gravity Forms IDs to check, comma-separated (blank = all active forms): " FORM_IDS

  cat > "$ENV_FILE" <<EOF
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
SITE_LABEL="${SITE_LABEL}"
WP_PATH=${WP_PATH}
WP_CLI_BIN=${WP_CLI_BIN}
WP_USER=${WP_USER}
LOOKBACK_HOURS=${LOOKBACK_HOURS}
ALERT_COOLDOWN_HOURS=${ALERT_COOLDOWN_HOURS}
FORM_IDS=${FORM_IDS}
STATE_DIR=
EOF
  chmod 600 "$ENV_FILE"
  echo
  echo "Wrote $ENV_FILE"
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a
WP_USER="${WP_USER:-www-data}"

chmod +x "$CHECK_SCRIPT"
mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/state"

echo
read -rp "Send a Slack test message now? [Y/n]: " DO_TEST
if [[ ! "${DO_TEST:-Y}" =~ ^[Nn] ]]; then
  "$CHECK_SCRIPT" --env "$ENV_FILE" --test-slack
fi

echo
echo "Sanity-checking wp-cli + Gravity Forms (this runs the real check once,"
echo "it will NOT alert unless there are genuinely zero submissions)..."
if "$CHECK_SCRIPT" --env "$ENV_FILE"; then
  echo "Check ran successfully. See $ROOT_DIR/logs/gf-monitor.log for details."
else
  echo "Check reported a problem — review the output above and $ROOT_DIR/logs/gf-monitor.log before relying on this." >&2
fi

echo
read -rp "Install a cron job to run this every 15 minutes as '$WP_USER'? [Y/n]: " DO_CRON
if [[ ! "${DO_CRON:-Y}" =~ ^[Nn] ]]; then
  if [[ $EUID -ne 0 ]] && [[ "$(whoami)" != "$WP_USER" ]]; then
    echo "Note: installing a crontab for another user usually needs root/sudo." >&2
  fi
  CRON_LINE="*/15 * * * * $CHECK_SCRIPT --env $ENV_FILE >> $ROOT_DIR/logs/cron.log 2>&1"
  ( crontab -u "$WP_USER" -l 2>/dev/null | grep -vF "$CHECK_SCRIPT" ; echo "$CRON_LINE" ) | crontab -u "$WP_USER" -
  echo "Installed cron job for $WP_USER:"
  echo "  $CRON_LINE"
else
  echo "Skipped. Add it yourself later with:"
  echo "  crontab -u $WP_USER -e"
  echo "  */15 * * * * $CHECK_SCRIPT --env $ENV_FILE >> $ROOT_DIR/logs/cron.log 2>&1"
fi

echo
echo "Setup complete. Config: $ENV_FILE"
