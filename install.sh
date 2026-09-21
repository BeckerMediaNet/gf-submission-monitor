#!/usr/bin/env bash
#
# install.sh — installer.
#
# On a new server:
#   curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/gf-submission-monitor/main/install.sh -o install.sh
#   sudo bash install.sh
#
# Download it first rather than piping straight into `sudo bash` — piping
# into sudo can detach the controlling terminal on some servers (sudo's
# use_pty and similar settings), which breaks the interactive prompts in
# setup.sh even over a normal SSH session.
#
# This clones (or updates) the repo into /opt/gf-monitor and hands off to
# setup.sh, which asks the configuration questions interactively.
#
# Running it again on a server that already has a configured monitor asks
# whether to reconfigure that one or set up an additional monitor (for
# another site on the same box) under /opt/gf-monitor-<name>.
#
# Override the directory explicitly (skips that prompt) with:
#   sudo GF_MONITOR_DIR=/opt/gf-monitor-clientname bash install.sh
#
set -euo pipefail

REPO_URL="${GF_MONITOR_REPO_URL:-https://github.com/BeckerMediaNet/gf-submission-monitor.git}"
BRANCH="${GF_MONITOR_BRANCH:-main}"

# Only run the "found an existing monitor" prompt below when the caller
# didn't already tell us exactly where to install (an explicit
# GF_MONITOR_DIR means they've made that decision already, e.g. scripted).
EXPLICIT_DIR=false
if [[ -n "${GF_MONITOR_DIR:-}" ]]; then
  EXPLICIT_DIR=true
fi
TARGET_DIR="${GF_MONITOR_DIR:-/opt/gf-monitor}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run this as root (sudo) — it installs into $TARGET_DIR and manages cron for the WordPress file-owner user." >&2
  exit 1
fi

for bin in git curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin is required and was not found on PATH." >&2; exit 1; }
done

if ! command -v wp >/dev/null 2>&1; then
  echo "Warning: wp-cli was not found on PATH. Install it before running the check:" >&2
  echo "  https://wp-cli.org/#installing" >&2
fi

no_terminal() {
  echo >&2
  echo "Couldn't read your answer — no usable terminal is attached to this process." >&2
  echo "Make sure you downloaded this script and ran it directly (sudo bash install.sh)" >&2
  echo "rather than piping it into bash." >&2
  exit 1
}

ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __val
  if ! IFS= read -rp "$__prompt" __val; then
    no_terminal
  fi
  printf -v "$__var" '%s' "${__val:-$__default}"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

if [[ "$EXPLICIT_DIR" == false ]] && [[ -f "$TARGET_DIR/.env" ]]; then
  EXISTING_LABEL="$(grep -m1 '^SITE_LABEL=' "$TARGET_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  echo "Found an already-configured monitor at $TARGET_DIR${EXISTING_LABEL:+ (site: $EXISTING_LABEL)}."
  echo
  echo "  1) Reconfigure/update this monitor"
  echo "  2) Set up an ADDITIONAL monitor for a different site on this server"
  echo
  ask CHOICE "Choice [1/2] (1): " "1"
  if [[ "$CHOICE" == "2" ]]; then
    SLUG=""
    while [[ -z "$SLUG" ]]; do
      ask SLUG_RAW "Short name for the new site (e.g. 'clienta') — installs to /opt/gf-monitor-<name>: "
      SLUG="$(slugify "$SLUG_RAW")"
      [[ -z "$SLUG" ]] && echo "Please enter at least one letter or number." >&2
    done
    TARGET_DIR="/opt/gf-monitor-${SLUG}"
    if [[ -f "$TARGET_DIR/.env" ]]; then
      echo "Note: $TARGET_DIR is already configured too — this will reconfigure that one."
    fi
  fi
  echo
fi

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "Existing install found at $TARGET_DIR — pulling latest..."
  git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH"
else
  echo "Cloning $REPO_URL into $TARGET_DIR..."
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$TARGET_DIR"
fi

chmod +x "$TARGET_DIR/setup.sh" "$TARGET_DIR/bin/check-gf-submissions.sh"
mkdir -p "$TARGET_DIR/logs" "$TARGET_DIR/state"

exec "$TARGET_DIR/setup.sh"
