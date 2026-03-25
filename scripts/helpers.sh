#!/usr/bin/env bash
# helpers.sh - Logging, identity, and state management for tmux-teams-magni

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config.sh if not already loaded (source guard prevents circular dependency)
if ! declare -f get_tmux_option &>/dev/null; then
    source "$CURRENT_DIR/config.sh"
fi

# Multi-user safe base directory
MAGNI_BASE_DIR="/tmp/tmux-magni-${UID}"

# log_magni(level, message...) — log with level filtering
# Level order: DEBUG < INFO < WARN < ERROR
log_magni() {
    local level="$1"
    shift
    local message="$*"

    local configured_level
    configured_level=$(get_tmux_option "@magni-log-level" "INFO")

    local -A level_order=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
    local msg_num="${level_order[$level]:-1}"
    local cfg_num="${level_order[$configured_level]:-1}"

    if [[ "$msg_num" -lt "$cfg_num" ]]; then
        return 0
    fi

    mkdir -p "$MAGNI_BASE_DIR"
    local log_file="$MAGNI_BASE_DIR/magni.log"
    local max_size=102400  # 100KB

    if [[ -f "$log_file" ]] && [[ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt $max_size ]]; then
        tail -200 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi

    local id
    id=$(daemon_id 2>/dev/null || echo "magni-unknown")
    echo "[$(date '+%H:%M:%S')] [$level] [$id] $message" >> "$log_file"
}

# daemon_id() — returns "magni-${session_id}-${window_id}"
daemon_id() {
    local session_id window_id
    session_id=$(tmux display-message -p '#{session_id}' 2>/dev/null)
    window_id=$(tmux display-message -p '#{window_id}' 2>/dev/null)
    echo "magni-${session_id}-${window_id}"
}

# pid_file() — returns path to PID file for current daemon
pid_file() {
    echo "$MAGNI_BASE_DIR/$(daemon_id).pid"
}

# state_dir() — returns state directory for current daemon, creating it if needed
state_dir() {
    local dir="$MAGNI_BASE_DIR/state/$(daemon_id)/"
    mkdir -p "$dir"
    echo "$dir"
}

# is_daemon_running() — checks if a magni daemon is alive
# Returns 0 if running, 1 if not
is_daemon_running() {
    local pf
    pf=$(pid_file)

    [[ -f "$pf" ]] || return 1

    local pid
    pid=$(cat "$pf")
    [[ -n "$pid" ]] || return 1

    kill -0 "$pid" 2>/dev/null || return 1

    # On Linux, verify cmdline contains "magni" (skip if /proc unavailable)
    if [[ -d /proc ]]; then
        local cmdline_file="/proc/${pid}/cmdline"
        if [[ -f "$cmdline_file" ]]; then
            grep -q "magni" "$cmdline_file" 2>/dev/null || return 1
        fi
    fi

    return 0
}

# cleanup_stale_state(state_dir, managed_pane_ids_string)
# Deletes hash_* and idle_* files whose pane ID suffix is NOT in managed_pane_ids_string
# managed_pane_ids_string is a newline-separated list of pane IDs
cleanup_stale_state() {
    local sd="$1"
    local managed_ids="$2"

    [[ -d "$sd" ]] || return 0

    local f basename pane_suffix
    for f in "$sd"/hash_* "$sd"/idle_*; do
        [[ -f "$f" ]] || continue
        basename="${f##*/}"
        # suffix after first underscore, with underscores restored to %
        pane_suffix="${basename#*_}"
        pane_suffix="${pane_suffix//_/%}"
        if ! echo "$managed_ids" | grep -qF "$pane_suffix"; then
            rm -f "$f"
        fi
    done
}

# abs_val(number) — returns absolute value
# Strips leading minus sign; works for all integers (POSIX pattern)
abs_val() {
    local n="$1"
    echo "${n#-}"
}
