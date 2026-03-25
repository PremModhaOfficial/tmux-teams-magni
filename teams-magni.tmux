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

# ── Default Options ──────────────────────────────────────────────────────
# All options use -gq (global, quiet — won't override user values already set)
tmux set-option -gq @magni-poll-interval "1"
tmux set-option -gq @magni-min-height "4"
tmux set-option -gq @magni-idle-threshold "3"
tmux set-option -gq @magni-enabled "1"
tmux set-option -gq @magni-max-daemons "5"
tmux set-option -gq @magni-idle-keywords "Baked for|Brewed for|Cogitated for|Pondered for|idle|waiting"
tmux set-option -gq @magni-log-level "INFO"
tmux set-option -gq @magni-deadband "1"
tmux set-option -gq @magni-detect-strategy "auto"

# ── Key Bindings ─────────────────────────────────────────────────────────
# Customizable via @magni-toggle-key and @magni-status-key in tmux.conf
toggle_key=$(tmux show-option -gqv @magni-toggle-key)
status_key=$(tmux show-option -gqv @magni-status-key)
tmux bind-key "${toggle_key:-M}" run-shell "$CURRENT_DIR/scripts/daemon.sh toggle"
tmux bind-key "${status_key:-M-m}" run-shell "$CURRENT_DIR/scripts/daemon.sh status"

# ── Lifecycle Hooks ──────────────────────────────────────────────────────
# Bug 10 fix: clean up daemons and state when sessions/windows close
tmux set-hook -ga session-closed "run-shell '$CURRENT_DIR/scripts/daemon.sh cleanup-session'"
tmux set-hook -ga window-closed "run-shell '$CURRENT_DIR/scripts/daemon.sh cleanup-window'"

# ── Auto-start ───────────────────────────────────────────────────────────
tmux run-shell -b "$CURRENT_DIR/scripts/daemon.sh start"
