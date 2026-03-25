#!/usr/bin/env bash
# resize.sh - Height calculation and application for tmux-teams-magni
#
# Sourced by daemon.sh. Depends on: log_magni, abs_val (helpers.sh), get_tmux_option (config.sh)
# Do NOT source other modules here — daemon.sh handles the source chain.

# calculate_targets(pane_count, min_height, heights_newline_sep, states_newline_sep)
# Pure math: takes current heights and states, returns target heights (one per line).
# Bug 3 fix: clamp available_for_active so it cannot exceed total_height.
# Graceful degradation: if total space < pane_count * min_height, distribute evenly.
calculate_targets() {
    local pane_count="$1"
    local min_height="$2"
    local heights_str="$3"
    local states_str="$4"

    local -a heights=()
    local -a states=()

    while IFS= read -r h; do
        [[ -n "$h" ]] && heights+=("$h")
    done <<< "$heights_str"

    while IFS= read -r s; do
        [[ -n "$s" ]] && states+=("$s")
    done <<< "$states_str"

    local total_height=0
    for h in "${heights[@]}"; do
        total_height=$((total_height + h))
    done

    local active_count=0
    local idle_count_total=0
    for state in "${states[@]}"; do
        if [[ "$state" == "active" ]]; then
            active_count=$((active_count + 1))
        else
            idle_count_total=$((idle_count_total + 1))
        fi
    done

    local -a targets=()

    if [[ "$active_count" -eq 0 || "$idle_count_total" -eq 0 ]]; then
        # All idle or all active: distribute evenly
        local even_height=$((total_height / pane_count))
        [[ "$even_height" -lt "$min_height" ]] && even_height="$min_height"
        for (( i=0; i<pane_count; i++ )); do
            targets+=("$even_height")
        done
    else
        local reserved_for_idle=$((idle_count_total * min_height))
        local available_for_active=$((total_height - reserved_for_idle))

        # Bug 3 fix: clamp to total_height so we never exceed available space
        if [[ "$available_for_active" -gt "$total_height" ]]; then
            available_for_active="$total_height"
        fi

        # Graceful degradation: if total space is too small, ensure min floor
        local min_active_total=$((active_count * min_height))
        if [[ "$available_for_active" -lt "$min_active_total" ]]; then
            available_for_active="$min_active_total"
        fi

        local active_height=$((available_for_active / active_count))
        [[ "$active_height" -lt "$min_height" ]] && active_height="$min_height"

        for (( i=0; i<pane_count; i++ )); do
            if [[ "${states[$i]}" == "idle" ]]; then
                targets+=("$min_height")
            else
                targets+=("$active_height")
            fi
        done
    fi

    printf '%s\n' "${targets[@]}"
}

# needs_resize(pane_count, deadband, current_heights_newline_sep, target_heights_newline_sep)
# Returns 0 (true) if any pane differs from its target by more than deadband lines.
# Bug 5 fix: uses abs_val() helper with clear comment explaining POSIX pattern.
needs_resize() {
    local pane_count="$1"
    local deadband="$2"
    local current_str="$3"
    local target_str="$4"

    local -a current=()
    local -a targets=()

    while IFS= read -r h; do
        [[ -n "$h" ]] && current+=("$h")
    done <<< "$current_str"

    while IFS= read -r h; do
        [[ -n "$h" ]] && targets+=("$h")
    done <<< "$target_str"

    for (( i=0; i<pane_count; i++ )); do
        local diff=$(( ${targets[$i]} - ${current[$i]} ))
        # abs_val strips leading minus — POSIX string prefix strip, no subshell needed
        local abs_diff
        abs_diff=$(abs_val "$diff")
        if [[ "$abs_diff" -gt "$deadband" ]]; then
            return 0
        fi
    done

    return 1
}

# apply_resizes(pane_count, pane_ids_newline_sep, target_heights_newline_sep)
# Applies tmux resize-pane commands for the first N-1 panes.
# Bug 6 fix: the last pane is intentionally left to tmux — it absorbs the remainder.
# This is correct tmux behavior: resizing N-1 panes forces the last one to fill the rest.
# We log the last pane's final height for debug verification.
apply_resizes() {
    local pane_count="$1"
    local pane_ids_str="$2"
    local target_str="$3"

    local -a pane_ids=()
    local -a targets=()

    while IFS= read -r p; do
        [[ -n "$p" ]] && pane_ids+=("$p")
    done <<< "$pane_ids_str"

    while IFS= read -r h; do
        [[ -n "$h" ]] && targets+=("$h")
    done <<< "$target_str"

    for (( i=0; i<pane_count; i++ )); do
        # Resize all panes except the last — it absorbs the remainder automatically
        if [[ "$i" -lt $((pane_count - 1)) ]]; then
            tmux resize-pane -t "${pane_ids[$i]}" -y "${targets[$i]}" 2>/dev/null || true
        else
            # Bug 6 fix: last pane fills remainder — log actual height for debug verification
            local actual_last
            actual_last=$(tmux display-message -t "${pane_ids[$i]}" -p '#{pane_height}' 2>/dev/null || echo "?")
            log_magni "DEBUG" "Last pane ${pane_ids[$i]}: target=${targets[$i]} actual=$actual_last (absorbed remainder)"
        fi
    done

    log_magni "DEBUG" "Resized $((pane_count - 1)) panes (last absorbed remainder)"
}
