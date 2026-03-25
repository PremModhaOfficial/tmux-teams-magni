#!/usr/bin/env bash
# panes.sh - Pane discovery and height queries for tmux-teams-magni

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# get_managed_panes() — discover the vertical pane stack to manage
# Groups panes by pane_left coordinate.
# Returns the group with the most members (the agent stack), sorted top-to-bottom by pane_top.
# Only returns pane IDs if the group has 2+ panes.
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

# get_pane_height(pane_id) — returns pane height in lines
get_pane_height() {
    local pane_id="$1"
    tmux display-message -t "$pane_id" -p '#{pane_height}' 2>/dev/null
}
