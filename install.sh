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
# Override defaults with env vars, e.g.:
#   sudo GF_MONITOR_DIR=/opt/gf-monitor-clientname bash install.sh
#
set -euo pipefail

REPO_URL="${GF_MONITOR_REPO_URL:-https://github.com/BeckerMediaNet/gf-submission-monitor.git}"
BRANCH="${GF_MONITOR_BRANCH:-main}"
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
