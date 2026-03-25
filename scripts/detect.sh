#!/usr/bin/env bash
# detect.sh - Pluggable activity detection for tmux-teams-magni
#
# Sourced by daemon.sh. Depends on: get_tmux_option (config.sh), log_magni, state_dir (helpers.sh)
# Do NOT source other modules here — daemon.sh handles the source chain.

# detect_pane_activity(pane_id, state_dir, poll_interval, idle_threshold)
# Dispatcher that selects detection strategy via @magni-detect-strategy option.
# Strategy values:
#   "auto" or "both" — keyword check first (fast path), then hash if not idle
#   "keywords"       — keyword check only
#   "hash"           — hash-based check only
# Echoes "active" or "idle" to stdout.
detect_pane_activity() {
    local pane_id="$1"
    local sd="$2"
    local poll_interval="$3"
    local idle_threshold="$4"

    local strategy
    strategy=$(get_tmux_option "@magni-detect-strategy" "auto")

    case "$strategy" in
        keywords)
            if detect_keyword_idle "$pane_id"; then
                echo "idle"
            else
                echo "active"
            fi
            ;;
        hash)
            detect_content_change "$pane_id" "$sd" "$poll_interval" "$idle_threshold"
            ;;
        auto|both|*)
            # Fast path: keyword check. If keyword match → idle immediately.
            if detect_keyword_idle "$pane_id"; then
                echo "idle"
                return 0
            fi
            # Slow path: hash-based check.
            detect_content_change "$pane_id" "$sd" "$poll_interval" "$idle_threshold"
            ;;
    esac
}

# detect_keyword_idle(pane_id)
# Checks the last 5 lines of the pane for any configured idle keywords.
# Keywords are read from @magni-idle-keywords (pipe-separated regex patterns).
# Default covers common OMC agent idle patterns.
# Returns 0 if an idle keyword is found, 1 otherwise.
detect_keyword_idle() {
    local pane_id="$1"

    local keywords
    keywords=$(get_tmux_option "@magni-idle-keywords" "Baked for|Brewed for|Cogitated for|Pondered for|idle|waiting")

    local pane_content
    pane_content=$(tmux capture-pane -t "$pane_id" -p -S -5 2>/dev/null) || return 1

    if echo "$pane_content" | grep -qE "$keywords" 2>/dev/null; then
        return 0
    fi
    return 1
}

# detect_content_change(pane_id, state_dir, poll_interval, idle_threshold)
# Hash-based detection. Compares current pane content hash to previous hash.
# Maintains a per-pane idle counter in state files.
# Echoes "active" or "idle" to stdout.
#
# State files:
#   $state_dir/hash_<safe_pane_id>  — last seen content hash
#   $state_dir/idle_<safe_pane_id>  — consecutive stable-hash cycle count
#
# Ceiling division is used to convert idle_threshold (seconds) to cycles,
# fixing integer truncation that could produce threshold_cycles=0.
detect_content_change() {
    local pane_id="$1"
    local sd="$2"
    local poll_interval="$3"
    local idle_threshold="$4"

    # Make pane_id filesystem-safe by replacing % with _
    local safe_pane_id="${pane_id//[%]/_}"
    local hash_file="$sd/hash_${safe_pane_id}"
    local counter_file="$sd/idle_${safe_pane_id}"

    # Capture current content hash
    local current_hash
    current_hash=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | cksum | cut -d' ' -f1) || current_hash=""

    # Read previous state
    local prev_hash=""
    [[ -f "$hash_file" ]] && prev_hash=$(cat "$hash_file")

    local idle_count=0
    [[ -f "$counter_file" ]] && idle_count=$(cat "$counter_file")

    # Update idle counter based on hash comparison
    if [[ "$current_hash" != "$prev_hash" ]]; then
        # Content changed: reset counter
        idle_count=0
    else
        # Content unchanged: increment counter
        idle_count=$((idle_count + 1))
    fi

    # Persist updated state
    echo "$current_hash" > "$hash_file"
    echo "$idle_count" > "$counter_file"

    # Ceiling division: (idle_threshold + poll_interval - 1) / poll_interval
    # Ensures threshold_cycles >= 1 even when idle_threshold < poll_interval
    local threshold_cycles
    threshold_cycles=$(( (idle_threshold + poll_interval - 1) / poll_interval ))

    if [[ "$idle_count" -ge "$threshold_cycles" ]]; then
        log_magni "DEBUG" "Pane $pane_id idle (count=$idle_count threshold=$threshold_cycles)"
        echo "idle"
    else
        echo "active"
    fi
}
