#!/usr/bin/env bash
# teams-magni.tmux - TPM entry point for tmux-teams-magni
#
# A tmux plugin that dynamically resizes panes based on activity.
# Active panes expand, idle panes shrink — perfect for watching
# parallel agent workflows like Claude Code teams.
#
# Install via TPM:
#   set -g @plugin 'your-user/tmux-teams-magni'
#
# Or manually source this file in tmux.conf:
#   run-shell /path/to/teams-magni.tmux

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Default Options (override in tmux.conf) ───────────────────────────
# Poll interval in seconds
tmux set-option -gq @magni-poll-interval "1"
# Minimum pane height (lines) for idle panes
tmux set-option -gq @magni-min-height "4"
# Seconds of no content change before a pane is considered idle
tmux set-option -gq @magni-idle-threshold "3"
# Enable/disable the plugin (1=on, 0=off)
tmux set-option -gq @magni-enabled "1"

# ─── Key Bindings ───────────────────────────────────────────────────────
# prefix + M  → toggle magni on/off
tmux bind-key M run-shell "$CURRENT_DIR/scripts/magni.sh toggle"
# prefix + Alt-m → show status
tmux bind-key M-m run-shell "$CURRENT_DIR/scripts/magni.sh status"

# ─── Auto-start Daemon ─────────────────────────────────────────────────
tmux run-shell -b "$CURRENT_DIR/scripts/magni.sh start"
