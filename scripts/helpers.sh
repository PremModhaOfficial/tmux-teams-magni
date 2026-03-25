#!/usr/bin/env bash
# helpers.sh - Shared utilities for tmux-teams-magni
# All configurable values flow through tmux options (@magni-*)

# Get a tmux option value, falling back to a default
get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null)
    if [[ -z "$value" ]]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

# Get window-level option with global fallback
get_window_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-window-option -qv "$option" 2>/dev/null)
    if [[ -z "$value" ]]; then
        get_tmux_option "$option" "$default_value"
    else
        echo "$value"
    fi
}

# Unique daemon identifier for this session+window
daemon_id() {
    local session window
    session=$(tmux display-message -p '#{session_id}' 2>/dev/null)
    window=$(tmux display-message -p '#{window_id}' 2>/dev/null)
    echo "magni-${session}-${window}"
}

pid_file() {
    echo "/tmp/tmux-$(daemon_id).pid"
}

state_dir() {
    local dir="/tmp/tmux-magni-state/$(daemon_id)"
    mkdir -p "$dir"
    echo "$dir"
}

# Hash pane content for change detection
capture_pane_hash() {
    local pane_id="$1"
    tmux capture-pane -t "$pane_id" -p 2>/dev/null | cksum | cut -d' ' -f1
}

# Check last lines of pane for OMC idle keywords
# Returns 0 (true) if idle keywords detected, 1 otherwise
check_omc_idle_keywords() {
    local pane_id="$1"
    local content
    content=$(tmux capture-pane -t "$pane_id" -p -S -5 2>/dev/null)
    # OMC agents show these words when idle
    if echo "$content" | grep -qiE '(Baked for|Brewed for|Cogitated for|Pondered for|idle|waiting)'; then
        return 0
    fi
    return 1
}

# Discover which panes to manage (vertical stack detection)
# Strategy: group panes by pane_left, manage the group with most members
get_managed_panes() {
    local window_id
    window_id=$(tmux display-message -p '#{window_id}' 2>/dev/null)

    # Get all pane info: pane_id, pane_left, pane_top
    local pane_data
    pane_data=$(tmux list-panes -t "$window_id" -F '#{pane_id}:#{pane_left}:#{pane_top}' 2>/dev/null)

    local pane_count
    pane_count=$(echo "$pane_data" | wc -l)

    # Need at least 2 panes total (1 orchestrator + 1 agent minimum)
    if [[ "$pane_count" -lt 2 ]]; then
        return
    fi

    # Find the pane_left value shared by the most panes (the vertical stack)
    local best_left=""
    local best_count=0

    while IFS= read -r left_val; do
        local count
        count=$(echo "$pane_data" | awk -F: -v l="$left_val" '$2 == l' | wc -l)
        if [[ "$count" -gt "$best_count" ]]; then
            best_count=$count
            best_left=$left_val
        fi
    done < <(echo "$pane_data" | cut -d: -f2 | sort -u)

    # Only manage if there are 2+ panes in the stack
    if [[ "$best_count" -ge 2 ]]; then
        # Return pane IDs sorted by pane_top (top to bottom)
        echo "$pane_data" | awk -F: -v l="$best_left" '$2 == l { print $1":"$3 }' \
            | sort -t: -k2 -n | cut -d: -f1
    fi
}

# Get current height of a pane
get_pane_height() {
    local pane_id="$1"
    tmux display-message -t "$pane_id" -p '#{pane_height}' 2>/dev/null
}

# Get total available height for managed panes
get_total_managed_height() {
    local total=0
    local pane_id
    while IFS= read -r pane_id; do
        [[ -z "$pane_id" ]] && continue
        local h
        h=$(get_pane_height "$pane_id")
        total=$((total + h))
    done
    echo "$total"
}

log_magni() {
    local level="$1"
    shift
    local log_file="/tmp/tmux-magni.log"
    local max_size=102400  # 100KB
    if [[ -f "$log_file" ]] && [[ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt $max_size ]]; then
        tail -100 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
    echo "[$(date '+%H:%M:%S')] [$level] $*" >> "$log_file"
}
