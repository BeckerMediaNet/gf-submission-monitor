#!/usr/bin/env bash
#
# check-gf-submissions.sh
#
# Checks whether a WordPress site running Gravity Forms has received any
# form submissions in the last N hours. If not, sends a Slack alert via
# an Incoming Webhook. Designed to run from system cron (not WP-Cron) so
# it keeps working even when the site itself is throwing 500/503 errors.
#
# Usage:
#   ./check-gf-submissions.sh                  # run the real check
#   ./check-gf-submissions.sh --test-slack      # send a Slack test message and exit
#   ./check-gf-submissions.sh --env /path/.env  # use a specific .env file
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
TEST_SLACK=false

# --- argument parsing -------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-slack)
      TEST_SLACK=true
      shift
      ;;
    --env)
      ENV_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing config file: $ENV_FILE (copy .env.example to .env and fill it in)" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL not set in $ENV_FILE}"
: "${WP_PATH:?WP_PATH not set in $ENV_FILE}"

SITE_LABEL="${SITE_LABEL:-$(hostname)}"
WP_CLI_BIN="${WP_CLI_BIN:-wp}"
WP_USER="${WP_USER:-www-data}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
ALERT_COOLDOWN_HOURS="${ALERT_COOLDOWN_HOURS:-6}"
FORM_IDS="${FORM_IDS:-}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/state}"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$STATE_DIR" "$LOG_DIR"
STATE_FILE="$STATE_DIR/last_alert.ts"
LOG_FILE="$LOG_DIR/gf-monitor.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

send_slack() {
  local text
  text="$(json_escape "$1")"
  curl -sS -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"${text}\"}" \
    "$SLACK_WEBHOOK_URL"
}

# --- test mode ---------------------------------------------------------
if [[ "$TEST_SLACK" == true ]]; then
  echo "Sending test message to Slack..."
  if send_slack ":white_check_mark: Test message from the Gravity Forms submission monitor on *${SITE_LABEL}* ($(hostname)). Slack connection is working."; then
    echo "Sent. Check the Slack channel tied to your webhook."
    exit 0
  else
    echo "Slack request failed. Check SLACK_WEBHOOK_URL in $ENV_FILE." >&2
    exit 1
  fi
fi

# --- real check ----------------------------------------------------------
WP_CMD=(sudo -u "$WP_USER" "$WP_CLI_BIN" eval-file "$ROOT_DIR/share/gf-count.php" "$LOOKBACK_HOURS" "$FORM_IDS" --path="$WP_PATH")

RESULT="$("${WP_CMD[@]}" 2>>"$LOG_FILE")"
WP_EXIT=$?

now_alert_allowed() {
  local now last
  now=$(date +%s)
  last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  (( now - last > ALERT_COOLDOWN_HOURS * 3600 ))
}

record_alert() {
  date +%s > "$STATE_FILE"
}

# WP-CLI itself failing (non-zero exit, empty output) usually means the
# site/DB/PHP is broken — exactly the scenario this monitor exists for.
if [[ $WP_EXIT -ne 0 || -z "$RESULT" ]]; then
  log "WP-CLI invocation failed (exit $WP_EXIT): $RESULT"
  if now_alert_allowed; then
    send_slack ":rotating_light: *${SITE_LABEL}*: Gravity Forms monitor could not run WP-CLI (exit code ${WP_EXIT}). The site or server may be down/broken — check it now."
    record_alert
  fi
  exit 1
fi

if [[ "$RESULT" == ERROR=* ]]; then
  log "gf-count.php reported: $RESULT"
  if now_alert_allowed; then
    send_slack ":warning: *${SITE_LABEL}*: Gravity Forms monitor error: ${RESULT#ERROR=}"
    record_alert
  fi
  exit 1
fi

COUNT="$(grep -oP '(?<=^COUNT=)[0-9]+' <<< "$RESULT" || true)"
LAST_ENTRY="$(grep -oP '(?<=^LAST_ENTRY=).*' <<< "$RESULT" || true)"
LAST_ENTRY="${LAST_ENTRY:-unknown}"

if [[ -z "$COUNT" ]]; then
  log "Could not parse wp-cli output: $RESULT"
  if now_alert_allowed; then
    send_slack ":warning: *${SITE_LABEL}*: Gravity Forms monitor got an unexpected result and could not parse it. Check the server log."
    record_alert
  fi
  exit 1
fi

log "Checked OK: COUNT=$COUNT LAST_ENTRY=$LAST_ENTRY"

if [[ "$COUNT" -eq 0 ]]; then
  if now_alert_allowed; then
    send_slack ":rotating_light: *${SITE_LABEL}*: No Gravity Forms submissions in the last ${LOOKBACK_HOURS}h (last submission: ${LAST_ENTRY}). Check site health and form functionality."
    record_alert
  fi
else
  # Recovery notice: only fires if we'd previously alerted.
  if [[ -f "$STATE_FILE" ]]; then
    send_slack ":white_check_mark: *${SITE_LABEL}*: Gravity Forms submissions have resumed (${COUNT} in the last ${LOOKBACK_HOURS}h). Clearing alert state."
    rm -f "$STATE_FILE"
  fi
fi

exit 0
