#!/usr/bin/env bash
# daemon.sh - Daemon lifecycle and main cycle for tmux-teams-magni
#
# Usage: daemon.sh {start|stop|toggle|status|cleanup-session|cleanup-window}

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all modules
source "$CURRENT_DIR/config.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/panes.sh"
source "$CURRENT_DIR/detect.sh"
source "$CURRENT_DIR/resize.sh"

# ─── Commands ────────────────────────────────────────────────────────────

cmd_start() {
    if is_daemon_running; then
        log_magni "INFO" "Daemon already running, skipping start"
        return 0
    fi

    # Bug 9 fix: cap number of concurrent daemons
    local max_daemons
    max_daemons=$(get_tmux_option "@magni-max-daemons" "5")
    local pid_dir="/tmp/tmux-magni-${UID}"
    local daemon_count=0
    if [[ -d "$pid_dir" ]]; then
        daemon_count=$(find "$pid_dir" -maxdepth 1 -name 'magni-*.pid' 2>/dev/null | wc -l)
    fi
    if [[ "$daemon_count" -ge "$max_daemons" ]]; then
        log_magni "WARN" "Max daemon count ($max_daemons) reached; not starting new daemon"
        return 0
    fi

    validate_config

    # Bug 1 fix: background the loop, then write PID from parent using $!
    # Do NOT write PID inside daemon_loop — that is a race condition.
    daemon_loop &
    echo "$!" > "$(pid_file)"

    log_magni "INFO" "Started daemon (pid=$!)"
}

cmd_stop() {
    if ! is_daemon_running; then
        return 0
    fi

    local pf
    pf=$(pid_file)
    local pid
    pid=$(cat "$pf")
    kill "$pid" 2>/dev/null || true
    rm -f "$pf"

    local sd
    sd=$(state_dir)
    rm -rf "$sd" 2>/dev/null || true

    log_magni "INFO" "Stopped daemon (pid=$pid)"
}

cmd_toggle() {
    local enabled
    enabled=$(get_tmux_option "@magni-enabled" "1")
    if [[ "$enabled" == "1" ]]; then
        tmux set-option -g @magni-enabled "0"
        tmux display-message "Magni: paused"
        log_magni "INFO" "Paused"
    else
        tmux set-option -g @magni-enabled "1"
        tmux display-message "Magni: active"
        log_magni "INFO" "Resumed"
    fi
}

cmd_status() {
    local pf
    pf=$(pid_file)
    if is_daemon_running; then
        local enabled
        enabled=$(get_tmux_option "@magni-enabled" "1")
        local panes
        panes=$(get_managed_panes 2>/dev/null || true)
        local pane_count=0
        [[ -n "$panes" ]] && pane_count=$(echo "$panes" | wc -l)
        if [[ "$enabled" == "1" ]]; then
            tmux display-message "Magni: running (pid=$(cat "$pf"), panes=$pane_count)"
        else
            tmux display-message "Magni: paused (pid=$(cat "$pf"), panes=$pane_count)"
        fi
    else
        tmux display-message "Magni: not running"
    fi
}

# ─── Daemon Loop ─────────────────────────────────────────────────────────

daemon_loop() {
    local pf
    pf=$(pid_file)

    # Bug 1 fix: PID is written by parent after backgrounding.
    # Trap still removes the file on exit for cleanup.
    trap 'rm -f "$pf"; exit 0' TERM INT EXIT

    log_magni "INFO" "Daemon loop started (pid=$$)"

    while true; do
        local enabled
        enabled=$(get_tmux_option "@magni-enabled" "1")
        if [[ "$enabled" != "1" ]]; then
            sleep 1
            continue
        fi

        local poll_interval
        poll_interval=$(get_tmux_option "@magni-poll-interval" "1")

        # Catch cycle errors so daemon survives transient tmux failures
        if ! magni_cycle; then
            log_magni "WARN" "Cycle failed, continuing"
        fi

        sleep "$poll_interval"
    done
}

# ─── Core Cycle ──────────────────────────────────────────────────────────

magni_cycle() {
    local sd
    sd=$(state_dir)

    local idle_threshold min_height poll_interval deadband
    idle_threshold=$(get_tmux_option "@magni-idle-threshold" "3")
    min_height=$(get_tmux_option "@magni-min-height" "4")
    poll_interval=$(get_tmux_option "@magni-poll-interval" "1")
    deadband=$(get_tmux_option "@magni-deadband" "1")

    # Snapshot pane list once (Bug 4 fix: single snapshot prevents mid-cycle desync)
    local panes
    panes=$(get_managed_panes)
    [[ -z "$panes" ]] && return 0

    local -a pane_ids=()
    while IFS= read -r pane_id; do
        [[ -z "$pane_id" ]] && continue
        pane_ids+=("$pane_id")
    done <<< "$panes"

    local pane_count="${#pane_ids[@]}"
    [[ "$pane_count" -lt 2 ]] && return 0

    # Bug 8 fix: clean up state files for panes no longer in the managed set
    cleanup_stale_state "$sd" "$panes"

    # ── Activity Detection ──

    local -a pane_states=()
    local -a live_pane_ids=()
    local -a live_pane_heights=()

    for pane_id in "${pane_ids[@]}"; do
        # Bug 4 fix: if tmux query fails (pane gone), skip it — don't desync arrays
        local height
        height=$(get_pane_height "$pane_id" 2>/dev/null) || continue
        [[ -z "$height" ]] && continue

        local state
        state=$(detect_pane_activity "$pane_id" "$sd" "$poll_interval" "$idle_threshold") || continue

        live_pane_ids+=("$pane_id")
        live_pane_heights+=("$height")
        pane_states+=("$state")
    done

    local live_count="${#live_pane_ids[@]}"
    [[ "$live_count" -lt 2 ]] && return 0

    # ── Resize Calculation and Application ──

    local -a target_heights=()
    target_heights=($(calculate_targets "$live_count" "$min_height" \
        "$(printf '%s\n' "${live_pane_heights[@]}")" \
        "$(printf '%s\n' "${pane_states[@]}")"))

    if needs_resize "$live_count" "$deadband" \
        "$(printf '%s\n' "${live_pane_heights[@]}")" \
        "$(printf '%s\n' "${target_heights[@]}")"; then
        apply_resizes "$live_count" \
            "$(printf '%s\n' "${live_pane_ids[@]}")" \
            "$(printf '%s\n' "${target_heights[@]}")"
    fi
}

# ─── Session/Window Cleanup Hooks ────────────────────────────────────────

# Bug 10 fix: called by session-closed hook to kill all daemons for the session
cmd_cleanup_session() {
    local pid_dir="/tmp/tmux-magni-${UID}"
    [[ -d "$pid_dir" ]] || return 0

    local pf pid
    for pf in "$pid_dir"/magni-*.pid; do
        [[ -f "$pf" ]] || continue
        pid=$(cat "$pf" 2>/dev/null) || continue
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$pf"
        log_magni "INFO" "Cleaned up daemon (pid=$pid) on session close"
    done

    # Remove state dirs for this session
    local session_id
    session_id=$(tmux display-message -p '#{session_id}' 2>/dev/null || true)
    if [[ -n "$session_id" ]]; then
        rm -rf "${pid_dir}/state/magni-${session_id}-"* 2>/dev/null || true
    fi
}

# Bug 10 fix: called by window-closed hook to kill the daemon for that window
cmd_cleanup_window() {
    local pf
    pf=$(pid_file)
    [[ -f "$pf" ]] || return 0

    local pid
    pid=$(cat "$pf" 2>/dev/null) || return 0
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$pf"

    local sd
    sd=$(state_dir)
    rm -rf "$sd" 2>/dev/null || true

    log_magni "INFO" "Cleaned up daemon (pid=$pid) on window close"
}

# ─── Entry Point ─────────────────────────────────────────────────────────

case "${1:-start}" in
    start)           cmd_start ;;
    stop)            cmd_stop ;;
    toggle)          cmd_toggle ;;
    status)          cmd_status ;;
    cleanup-session) cmd_cleanup_session ;;
    cleanup-window)  cmd_cleanup_window ;;
    *)
        echo "Usage: daemon.sh {start|stop|toggle|status|cleanup-session|cleanup-window}"
        exit 1
        ;;
esac
