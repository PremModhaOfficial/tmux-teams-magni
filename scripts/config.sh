#!/usr/bin/env bash
# config.sh - Option access and validation for tmux-teams-magni

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# get_tmux_option(option, default) — get global tmux option with fallback
get_tmux_option() {
    local option="$1" default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null)
    if [[ -z "$value" ]]; then echo "$default_value"; else echo "$value"; fi
}

# validate_config() — validate all @magni-* options, warn and fix invalid values
# Requires log_magni from helpers.sh — caller (daemon.sh) must source helpers.sh first.
validate_config() {
    local value

    # @magni-poll-interval: integer >= 1, default 1
    value=$(get_tmux_option "@magni-poll-interval" "1")
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        log_magni "WARN" "@magni-poll-interval='$value' is invalid (must be integer >= 1); resetting to 1"
        tmux set-option -g "@magni-poll-interval" "1"
    fi

    # @magni-min-height: integer >= 2, default 4
    value=$(get_tmux_option "@magni-min-height" "4")
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 2 ]]; then
        log_magni "WARN" "@magni-min-height='$value' is invalid (must be integer >= 2); resetting to 4"
        tmux set-option -g "@magni-min-height" "4"
    fi

    # @magni-idle-threshold: integer >= 1, default 3
    value=$(get_tmux_option "@magni-idle-threshold" "3")
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        log_magni "WARN" "@magni-idle-threshold='$value' is invalid (must be integer >= 1); resetting to 3"
        tmux set-option -g "@magni-idle-threshold" "3"
    fi

    # @magni-enabled: 0 or 1, default 1
    value=$(get_tmux_option "@magni-enabled" "1")
    if [[ "$value" != "0" && "$value" != "1" ]]; then
        log_magni "WARN" "@magni-enabled='$value' is invalid (must be 0 or 1); resetting to 1"
        tmux set-option -g "@magni-enabled" "1"
    fi

    # @magni-max-daemons: integer >= 1, default 5
    value=$(get_tmux_option "@magni-max-daemons" "5")
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        log_magni "WARN" "@magni-max-daemons='$value' is invalid (must be integer >= 1); resetting to 5"
        tmux set-option -g "@magni-max-daemons" "5"
    fi

    # @magni-log-level: DEBUG|INFO|WARN|ERROR, default INFO
    value=$(get_tmux_option "@magni-log-level" "INFO")
    if [[ "$value" != "DEBUG" && "$value" != "INFO" && "$value" != "WARN" && "$value" != "ERROR" ]]; then
        log_magni "WARN" "@magni-log-level='$value' is invalid (must be DEBUG|INFO|WARN|ERROR); resetting to INFO"
        tmux set-option -g "@magni-log-level" "INFO"
    fi

    # @magni-deadband: integer >= 0, default 1
    value=$(get_tmux_option "@magni-deadband" "1")
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_magni "WARN" "@magni-deadband='$value' is invalid (must be integer >= 0); resetting to 1"
        tmux set-option -g "@magni-deadband" "1"
    fi

    # @magni-detect-strategy: auto|keywords|hash|both, default auto
    value=$(get_tmux_option "@magni-detect-strategy" "auto")
    if [[ "$value" != "auto" && "$value" != "keywords" && "$value" != "hash" && "$value" != "both" ]]; then
        log_magni "WARN" "@magni-detect-strategy='$value' is invalid (must be auto|keywords|hash|both); resetting to auto"
        tmux set-option -g "@magni-detect-strategy" "auto"
    fi
}
