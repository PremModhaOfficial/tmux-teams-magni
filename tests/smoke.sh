#!/usr/bin/env bash
# Smoke test for tmux-teams-magni modules
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/panes.sh"
source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/resize.sh"

pass=0
fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $name"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name (expected='$expected' actual='$actual')"
        fail=$((fail + 1))
    fi
}

echo "=== Source Chain ==="
echo "  PASS: all modules sourced"
pass=$((pass + 1))

echo "=== config.sh ==="
check "get_tmux_option fallback" "fallback" "$(get_tmux_option "@magni-nonexistent" "fallback")"
check "get_tmux_option real" "1" "$(get_tmux_option "@magni-enabled" "1")"

echo "=== helpers.sh ==="
check "abs_val(-5)" "5" "$(abs_val -5)"
check "abs_val(3)" "3" "$(abs_val 3)"
check "abs_val(0)" "0" "$(abs_val 0)"

id=$(daemon_id)
[[ -n "$id" ]] && check "daemon_id not empty" "true" "true" || check "daemon_id not empty" "true" "false"

pf=$(pid_file)
[[ "$pf" == *"magni-"* ]] && check "pid_file contains magni" "true" "true" || check "pid_file contains magni" "true" "false"

echo "=== panes.sh ==="
panes=$(get_managed_panes)
check "single-pane returns empty" "" "$panes"

echo "=== resize.sh ==="

# All active: even distribution
targets=$(calculate_targets 3 4 "$(printf '20\n20\n20')" "$(printf 'active\nactive\nactive')")
check "all-active even split" "20 20 20" "$(echo "$targets" | tr '\n' ' ' | sed 's/ *$//')"

# All idle: even distribution
targets=$(calculate_targets 3 4 "$(printf '20\n20\n20')" "$(printf 'idle\nidle\nidle')")
check "all-idle even split" "20 20 20" "$(echo "$targets" | tr '\n' ' ' | sed 's/ *$//')"

# Mixed: idle=min_height(4), active gets rest. Total=60, idle=1*4=4, active_avail=56, per_active=28
targets=$(calculate_targets 3 4 "$(printf '20\n20\n20')" "$(printf 'active\nidle\nactive')")
check "mixed: active gets more" "28 4 28" "$(echo "$targets" | tr '\n' ' ' | sed 's/ *$//')"

# needs_resize: large diff
if needs_resize 3 1 "$(printf '20\n20\n20')" "$(printf '20\n4\n36')"; then
    check "needs_resize detects diff" "true" "true"
else
    check "needs_resize detects diff" "true" "false"
fi

# needs_resize: within deadband
if needs_resize 3 1 "$(printf '20\n20\n20')" "$(printf '20\n20\n21')"; then
    check "within deadband no resize" "false" "true"
else
    check "within deadband no resize" "false" "false"
fi

echo "=== detect.sh ==="
sd=$(state_dir)
pane_id=$(tmux display-message -p '#{pane_id}')
activity=$(detect_pane_activity "$pane_id" "$sd" 1 3)
[[ "$activity" == "active" || "$activity" == "idle" ]] && check "detect returns valid state" "true" "true" || check "detect returns valid state" "true" "false"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
