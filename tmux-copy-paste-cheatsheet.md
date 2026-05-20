# Tmux Copy/Paste Cheat Sheet

Workaround for apps (e.g. dot-agent-deck) that capture the mouse and break normal terminal copy/paste.

## One-Time Setup

Run once per tmux session to enable vi-style copy mode:

```bash
tmux set -g mode-keys vi
```

To make it permanent, add to `~/.tmux.conf`:

```
set -g mode-keys vi
```

## Copy Text from a Pane

| Step | Action |
|------|--------|
| 1 | `Ctrl+b [` — enter copy mode (look for `[123/456]` counter in top-right) |
| 2 | Arrow keys — move cursor to start of text |
| 3 | `Space` — begin selection (text highlights as you move) |
| 4 | Arrow keys — extend selection to end of text |
| 5 | `Enter` — copy selection to tmux clipboard (exits copy mode) |

## Paste

| Destination | Command |
|-------------|---------|
| Same tmux pane | `Ctrl+b ]` |
| System clipboard (Ctrl+V) | `tmux show-buffer \| xclip -selection clipboard` |

## Exit Copy Mode Without Copying

Press `q` or `Escape`.

## Related

- Issue: vfarcic/dot-agent-deck#96 — mouse capture breaks GNOME Terminal copy/paste
- Issue: vfarcic/dot-agent-deck#98 — testing the tmux workaround
