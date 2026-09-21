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

no_terminal() {
  echo >&2
  echo "Couldn't read your answer — no usable terminal is attached to this process." >&2
  echo "This happens when the script is piped into bash (stdin is the pipe, not the" >&2
  echo "keyboard), or when running inside something like tmux/screen/a web console" >&2
  echo "that doesn't provide a real controlling terminal." >&2
  echo >&2
  echo "Download it and run it directly instead of piping it in:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/gf-submission-monitor/main/install.sh -o install.sh" >&2
  echo "  sudo bash install.sh" >&2
  exit 1
}

# ask <varname> <prompt> [default]
# Wraps `read` so a real read failure (broken/missing terminal) aborts with
# a clear message instead of silently defaulting or looping forever — only
# an empty ENTER press falls back to the default.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __val
  if ! IFS= read -rp "$__prompt" __val; then
    no_terminal
  fi
  printf -v "$__var" '%s' "${__val:-$__default}"
}

# ask_required <varname> <prompt>
# Like ask, but keeps asking until a non-empty answer is given. A genuine
# read failure still aborts immediately rather than looping.
ask_required() {
  local __var="$1" __prompt="$2" __val=""
  while [[ -z "$__val" ]]; do
    if ! IFS= read -rp "$__prompt" __val; then
      no_terminal
    fi
  done
  printf -v "$__var" '%s' "$__val"
}

# When this script is run via `curl ... | sudo bash` (as install.sh does),
# stdin is the pipe carrying the script text itself, not the keyboard. If
# stdin isn't already an interactive terminal, try switching to the real
# terminal device — but only when stdin needs it, so a normal, already-
# interactive run (e.g. downloaded and run directly) is left alone.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec < /dev/tty
fi

echo "=================================================================="
echo " Gravity Forms Submission Monitor — setup"
echo " Installing into: $ROOT_DIR"
echo "=================================================================="
echo

if [[ -f "$ENV_FILE" ]]; then
  echo "A .env already exists at $ENV_FILE."
  ask OVERWRITE "Overwrite it with new answers? [y/N]: " "N"
  if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
    echo "Keeping existing .env. Re-run with that answer set to 'y' to redo it."
    SKIP_ENV=true
  fi
fi

if [[ "${SKIP_ENV:-false}" != true ]]; then
  ask SITE_LABEL "Site label (e.g. 'Acme Co - acme.com'): "

  echo
  echo "Is WordPress running directly on this server, or inside Docker?"
  ask DEPLOY_MODE "Deploy mode [host/docker] (host): " "host"
  DEPLOY_MODE="$(echo "$DEPLOY_MODE" | tr '[:upper:]' '[:lower:]')"

  DOCKER_CONTAINER=""
  if [[ "$DEPLOY_MODE" == "docker" ]]; then
    if command -v docker >/dev/null 2>&1; then
      echo
      echo "Running containers on this server:"
      docker ps --format '  {{.Names}}   ({{.Image}})' || echo "  (couldn't list containers — is docker accessible without sudo here?)"
      echo
    else
      echo "Note: docker isn't on PATH for this shell — you may need to run setup.sh with sudo, or check the container name another way (docker ps)." >&2
    fi
    ask_required DOCKER_CONTAINER "Name of the running container that has wp-cli available: "

    ask WP_PATH "WordPress path INSIDE the container [/var/www/html]: " "/var/www/html"
    ask WP_USER "User to run wp-cli as INSIDE the container [www-data]: " "www-data"

    WP_CLI_BIN="wp"

    echo
    echo "The cron job that runs this check needs permission to run 'docker exec'"
    echo "(root, or a user in the 'docker' group)."
    ask CRON_USER "Which host user should the cron job run as? [root]: " "root"
  else
    ask WP_PATH "WordPress path (folder with wp-config.php) [/var/www/html]: " "/var/www/html"
    ask WP_USER "Linux user that owns the WordPress files [www-data]: " "www-data"

    DEFAULT_WP_BIN="$(command -v wp || true)"
    ask WP_CLI_BIN "wp-cli binary path [${DEFAULT_WP_BIN:-wp}]: " "${DEFAULT_WP_BIN:-wp}"

    CRON_USER="$WP_USER"
  fi

  ask_required SLACK_WEBHOOK_URL "Slack Incoming Webhook URL: "

  ask LOOKBACK_HOURS "Lookback window in hours [24]: " "24"
  ask ALERT_COOLDOWN_HOURS "Alert cooldown in hours, to avoid repeat alerts [6]: " "6"
  ask FORM_IDS "Specific Gravity Forms IDs to check, comma-separated (blank = all active forms): "

  cat > "$ENV_FILE" <<EOF
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
SITE_LABEL="${SITE_LABEL}"
DEPLOY_MODE=${DEPLOY_MODE}
WP_PATH=${WP_PATH}
WP_CLI_BIN=${WP_CLI_BIN}
WP_USER=${WP_USER}
DOCKER_CONTAINER=${DOCKER_CONTAINER}
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
DEPLOY_MODE="${DEPLOY_MODE:-host}"
CRON_USER="${CRON_USER:-$([[ "$DEPLOY_MODE" == "docker" ]] && echo root || echo "$WP_USER")}"

chmod +x "$CHECK_SCRIPT"
mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/state"

echo
ask DO_TEST "Send a Slack test message now? [Y/n]: " "Y"
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
ask DO_CRON "Install a cron job to run this every 15 minutes as '$CRON_USER'? [Y/n]: " "Y"
if [[ ! "${DO_CRON:-Y}" =~ ^[Nn] ]]; then
  if [[ $EUID -ne 0 ]] && [[ "$(whoami)" != "$CRON_USER" ]]; then
    echo "Note: installing a crontab for another user usually needs root/sudo." >&2
  fi
  CRON_LINE="*/15 * * * * $CHECK_SCRIPT --env $ENV_FILE >> $ROOT_DIR/logs/cron.log 2>&1"
  ( crontab -u "$CRON_USER" -l 2>/dev/null | grep -vF "$CHECK_SCRIPT" ; echo "$CRON_LINE" ) | crontab -u "$CRON_USER" -
  echo "Installed cron job for $CRON_USER:"
  echo "  $CRON_LINE"
else
  echo "Skipped. Add it yourself later with:"
  echo "  crontab -u $CRON_USER -e"
  echo "  */15 * * * * $CHECK_SCRIPT --env $ENV_FILE >> $ROOT_DIR/logs/cron.log 2>&1"
fi

echo
echo "Setup complete. Config: $ENV_FILE"
