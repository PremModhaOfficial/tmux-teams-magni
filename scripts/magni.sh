#!/usr/bin/env bash
# magni.sh - Main daemon for tmux-teams-magni
# Polls pane content, detects activity, and resizes panes dynamically.
#
# Usage: magni.sh {start|stop|toggle|status}

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

# ─── Commands ───────────────────────────────────────────────────────────

cmd_start() {
    cmd_stop 2>/dev/null || true
    log_magni "INFO" "Starting magni daemon"
    (daemon_loop &)
    # Give the backgrounded process a moment to write its PID
    sleep 0.2
}

cmd_stop() {
    local pf
    pf=$(pid_file)
    if [[ -f "$pf" ]]; then
        local pid
        pid=$(cat "$pf")
        kill "$pid" 2>/dev/null || true
        rm -f "$pf"
        log_magni "INFO" "Stopped daemon (pid=$pid)"
    fi
    # Clean up state
    local sd
    sd=$(state_dir)
    rm -rf "$sd" 2>/dev/null || true
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
    if [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null; then
        local enabled
        enabled=$(get_tmux_option "@magni-enabled" "1")
        if [[ "$enabled" == "1" ]]; then
            tmux display-message "Magni: running (pid=$(cat "$pf"))"
        else
            tmux display-message "Magni: paused (pid=$(cat "$pf"))"
        fi
    else
        tmux display-message "Magni: not running"
    fi
}

# ─── Daemon Loop ────────────────────────────────────────────────────────

daemon_loop() {
    # Detach from terminal, write PID
    local pf
    pf=$(pid_file)
    echo $$ > "$pf"

    trap 'rm -f "$pf"; exit 0' TERM INT EXIT

    log_magni "INFO" "Daemon loop started (pid=$$)"

    while true; do
        # Check if still enabled
        local enabled
        enabled=$(get_tmux_option "@magni-enabled" "1")
        if [[ "$enabled" != "1" ]]; then
            sleep 1
            continue
        fi

        local poll_interval
        poll_interval=$(get_tmux_option "@magni-poll-interval" "1")

        # Run one cycle, catch errors so daemon doesn't die
        if ! magni_cycle; then
            log_magni "WARN" "Cycle failed, continuing"
        fi

        sleep "$poll_interval"
    done
}

# ─── Core Logic ─────────────────────────────────────────────────────────

magni_cycle() {
    local sd
    sd=$(state_dir)
    local idle_threshold
    idle_threshold=$(get_tmux_option "@magni-idle-threshold" "3")
    local min_height
    min_height=$(get_tmux_option "@magni-min-height" "4")
    local poll_interval
    poll_interval=$(get_tmux_option "@magni-poll-interval" "1")

    # Discover managed panes
    local panes
    panes=$(get_managed_panes)
    [[ -z "$panes" ]] && return 0

    local pane_count=0
    local -a pane_ids=()
    local -a pane_states=()  # "active" or "idle"

    while IFS= read -r pane_id; do
        [[ -z "$pane_id" ]] && continue
        pane_ids+=("$pane_id")
        pane_count=$((pane_count + 1))
    done <<< "$panes"

    # Need at least 2 panes to do anything useful
    [[ "$pane_count" -lt 2 ]] && return 0

    # ── Activity Detection ──

    for pane_id in "${pane_ids[@]}"; do
        local hash_file="$sd/hash_${pane_id//[%]/_}"
        local counter_file="$sd/idle_${pane_id//[%]/_}"

        local current_hash
        current_hash=$(capture_pane_hash "$pane_id")

        local prev_hash=""
        [[ -f "$hash_file" ]] && prev_hash=$(cat "$hash_file")

        local idle_count=0
        [[ -f "$counter_file" ]] && idle_count=$(cat "$counter_file")

        # Fast-path: OMC idle keyword detection
        if check_omc_idle_keywords "$pane_id"; then
            idle_count=$((idle_threshold + 1))
        elif [[ "$current_hash" == "$prev_hash" ]]; then
            idle_count=$((idle_count + 1))
        else
            idle_count=0
        fi

        echo "$current_hash" > "$hash_file"
        echo "$idle_count" > "$counter_file"

        # Calculate idle threshold in cycles
        local threshold_cycles
        threshold_cycles=$(( idle_threshold / poll_interval ))
        [[ "$threshold_cycles" -lt 1 ]] && threshold_cycles=1

        if [[ "$idle_count" -ge "$threshold_cycles" ]]; then
            pane_states+=("idle")
        else
            pane_states+=("active")
        fi
    done

    # ── Resize Calculation ──

    local total_height=0
    local -a current_heights=()
    for pane_id in "${pane_ids[@]}"; do
        local h
        h=$(get_pane_height "$pane_id")
        current_heights+=("$h")
        total_height=$((total_height + h))
    done

    # Count active vs idle
    local active_count=0
    local idle_count_total=0
    for state in "${pane_states[@]}"; do
        if [[ "$state" == "active" ]]; then
            active_count=$((active_count + 1))
        else
            idle_count_total=$((idle_count_total + 1))
        fi
    done

    # Calculate target heights
    local -a target_heights=()

    if [[ "$active_count" -eq 0 ]]; then
        # All idle: distribute evenly
        local even_height=$((total_height / pane_count))
        for (( i=0; i<pane_count; i++ )); do
            target_heights+=("$even_height")
        done
    elif [[ "$idle_count_total" -eq 0 ]]; then
        # All active: distribute evenly
        local even_height=$((total_height / pane_count))
        for (( i=0; i<pane_count; i++ )); do
            target_heights+=("$even_height")
        done
    else
        # Mix: idle panes get min_height, active panes share the rest
        local reserved_for_idle=$((idle_count_total * min_height))
        local available_for_active=$((total_height - reserved_for_idle))

        # Guard against negative/zero
        if [[ "$available_for_active" -lt "$((active_count * min_height))" ]]; then
            available_for_active=$((active_count * min_height))
        fi

        local active_height=$((available_for_active / active_count))

        for (( i=0; i<pane_count; i++ )); do
            if [[ "${pane_states[$i]}" == "idle" ]]; then
                target_heights+=("$min_height")
            else
                target_heights+=("$active_height")
            fi
        done
    fi

    # ── Apply Resizes ──
    # Only resize if targets differ from current (avoid flicker)

    local needs_resize=false
    for (( i=0; i<pane_count; i++ )); do
        local diff=$(( ${target_heights[$i]} - ${current_heights[$i]} ))
        # Deadband: only resize if difference > 1 line (prevents jitter)
        if [[ "${diff#-}" -gt 1 ]]; then
            needs_resize=true
            break
        fi
    done

    if [[ "$needs_resize" == "true" ]]; then
        # Resize all panes except the last (it absorbs remainder)
        for (( i=0; i<pane_count-1; i++ )); do
            tmux resize-pane -t "${pane_ids[$i]}" -y "${target_heights[$i]}" 2>/dev/null || true
        done
        log_magni "DEBUG" "Resized: active=$active_count idle=$idle_count_total"
    fi
}

# ─── Entry Point ────────────────────────────────────────────────────────

case "${1:-start}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    toggle) cmd_toggle ;;
    status) cmd_status ;;
    *)
        echo "Usage: magni.sh {start|stop|toggle|status}"
        exit 1
        ;;
esac
