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
DEPLOY_MODE="${DEPLOY_MODE:-host}"
WP_CLI_BIN="${WP_CLI_BIN:-wp}"
WP_USER="${WP_USER:-www-data}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}"
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

# --- build the PHP to run via `wp eval` -----------------------------------
# Passed as a single inline string (not a file) so this works identically
# whether wp-cli runs on the host or inside a Docker container — no file
# needs to exist inside the container's filesystem.
build_php_code() {
  local template
  template=$(cat <<'PHPEOF'
if (!class_exists('GFAPI')) {
    echo "ERROR=Gravity Forms plugin not found or not active\n";
    return;
}
$lookback_hours = (int) '__LOOKBACK_HOURS__';
if ($lookback_hours <= 0) { $lookback_hours = 24; }
$form_id_arg = '__FORM_IDS__';
if ($form_id_arg !== '') {
    $form_ids = array_filter(array_map('trim', explode(',', $form_id_arg)));
} else {
    $all_forms = GFAPI::get_forms(true, false);
    if (is_wp_error($all_forms)) {
        echo "ERROR=Could not load forms: " . $all_forms->get_error_message() . "\n";
        return;
    }
    $form_ids = wp_list_pluck($all_forms, 'id');
}
if (empty($form_ids)) {
    echo "ERROR=No active Gravity Forms forms found to check\n";
    return;
}
$start_date = gmdate('Y-m-d H:i:s', time() - ($lookback_hours * HOUR_IN_SECONDS));
$total = 0;
foreach ($form_ids as $form_id) {
    $search_criteria = array('status' => 'active', 'start_date' => $start_date);
    $count = GFAPI::count_entries($form_id, $search_criteria);
    if (is_wp_error($count)) { continue; }
    $total += (int) $count;
}
$last_entry_date = 'never';
$recent = GFAPI::get_entries($form_ids, array('status' => 'active'), array('key' => 'date_created', 'direction' => 'DESC'), array('offset' => 0, 'page_size' => 1));
if (!is_wp_error($recent) && !empty($recent)) {
    $last_entry_date = $recent[0]['date_created'];
}
echo "COUNT={$total}\n";
echo "LAST_ENTRY={$last_entry_date}\n";
echo 'FORMS_CHECKED=' . implode(',', $form_ids) . "\n";
PHPEOF
)
  template="${template//__LOOKBACK_HOURS__/$LOOKBACK_HOURS}"
  template="${template//__FORM_IDS__/$FORM_IDS}"
  printf '%s' "$template"
}

PHP_CODE="$(build_php_code)"

# --- real check ----------------------------------------------------------
if [[ "$DEPLOY_MODE" == "docker" ]]; then
  : "${DOCKER_CONTAINER:?DOCKER_CONTAINER not set in $ENV_FILE (DEPLOY_MODE=docker)}"
  command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }
  WP_CMD=(docker exec -u "$WP_USER" "$DOCKER_CONTAINER" "$WP_CLI_BIN" eval "$PHP_CODE" --path="$WP_PATH")
else
  WP_CMD=(sudo -u "$WP_USER" "$WP_CLI_BIN" eval "$PHP_CODE" --path="$WP_PATH")
fi

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
# site/DB/PHP is broken (or, in Docker mode, the container isn't running) —
# exactly the scenario this monitor exists for.
if [[ $WP_EXIT -ne 0 || -z "$RESULT" ]]; then
  log "WP-CLI invocation failed (exit $WP_EXIT, mode=$DEPLOY_MODE): $RESULT"
  if now_alert_allowed; then
    send_slack ":rotating_light: *${SITE_LABEL}*: Gravity Forms monitor could not run WP-CLI (exit code ${WP_EXIT}). The site, container, or server may be down/broken — check it now."
    record_alert
  fi
  exit 1
fi

if [[ "$RESULT" == ERROR=* ]]; then
  log "wp eval reported: $RESULT"
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
