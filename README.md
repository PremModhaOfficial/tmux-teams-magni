# tmux-teams-magni

Dynamic pane resizer for tmux — active panes expand, idle panes shrink. Works with TPM.

Built for parallel agent workflows: when running multiple Claude Code agents in a vertical
pane stack, the active agent's pane grows to readable size while idle agents compress to
minimal footprint. Auto-detects vertical pane stacks, no manual configuration required.

## Installation

### Via TPM (recommended)

Add to `~/.tmux.conf`:

```
set -g @plugin 'prem-modha/tmux-teams-magni'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/prem-modha/tmux-teams-magni ~/.tmux/plugins/tmux-teams-magni
```

Add to `~/.tmux.conf`:

```
run-shell ~/.tmux/plugins/tmux-teams-magni/teams-magni.tmux
```

## Configuration

All options are set in `~/.tmux.conf` with `set -g`. Defaults are shown.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `@magni-poll-interval` | integer >= 1 | `1` | Seconds between detection cycles |
| `@magni-min-height` | integer >= 2 | `4` | Minimum height (lines) for idle panes |
| `@magni-idle-threshold` | integer >= 1 | `3` | Seconds of no change before pane is idle |
| `@magni-enabled` | 0 or 1 | `1` | Enable (1) or disable (0) the plugin |
| `@magni-max-daemons` | integer >= 1 | `5` | Max concurrent daemon processes |
| `@magni-idle-keywords` | pipe-separated regex | `Baked for\|...` | Patterns that immediately mark a pane idle |
| `@magni-log-level` | DEBUG/INFO/WARN/ERROR | `INFO` | Log verbosity |
| `@magni-deadband` | integer >= 0 | `1` | Minimum height delta before resize fires |
| `@magni-detect-strategy` | auto/keywords/hash/both | `auto` | Detection algorithm (see below) |
| `@magni-toggle-key` | key name | `M` | Key for prefix+key toggle binding |
| `@magni-status-key` | key name | `M-m` | Key for prefix+key status binding |

Example customization:

```
set -g @magni-min-height 6
set -g @magni-idle-threshold 5
set -g @magni-idle-keywords "waiting|idle|done|Baked for"
```

## Key Bindings

| Binding | Action |
|---------|--------|
| `prefix + M` | Toggle magni on/off |
| `prefix + Alt-m` | Show daemon status |

Customize via `@magni-toggle-key` and `@magni-status-key`.

## How Detection Works

Each cycle, every pane in the managed stack is evaluated:

1. **Keyword fast-path** (`auto`/`keywords`/`both`): the last 5 lines of the pane are
   checked against `@magni-idle-keywords` patterns. A match immediately marks the pane
   idle — no waiting for the hash threshold.

2. **Hash-based tracking** (`auto`/`hash`/`both`): a checksum of the full pane content
   is compared to the previous cycle's checksum. If the content is unchanged for
   `@magni-idle-threshold` seconds (using ceiling division to avoid truncation to 0),
   the pane is marked idle.

Set `@magni-detect-strategy "keywords"` for pure keyword detection, `"hash"` for pure
hash, or `"auto"`/`"both"` for keyword-first with hash fallback.

## Troubleshooting

**Log file location:**

```
/tmp/tmux-magni-$UID/magni.log
```

**Enable debug logging:**

```
set -g @magni-log-level "DEBUG"
```

Then reload tmux config and restart the daemon (`prefix + M` twice to toggle off/on).

**Common issues:**

- *Daemon not starting*: check the log file. Verify `tmux run-shell` works in your version.
- *Panes not resizing*: ensure the window has 2+ panes in a vertical stack (same `pane_left`).
- *Stale daemon after crash*: the plugin detects stale PID files via `/proc` cmdline check and
  cleans them automatically on next start.
- *Too many daemons*: lower `@magni-max-daemons` or run `daemon.sh cleanup-session` manually.
