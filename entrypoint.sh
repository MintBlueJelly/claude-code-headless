#!/usr/bin/env bash
# PID 1 of the claude-code-remote pod.
#
# Installs/locates the Claude Code CLI on the bind-mounted home dir, then runs it
# in remote-control mode under tmux so that:
#   * claude.ai can pair to the session (outbound, no ingress required), and
#   * `kubectl exec -it <pod> -- tmux attach -t claude` gives a live terminal.
# The tmux pane is streamed to PID 1 stdout so `kubectl logs` still works.
set -euo pipefail

BIN="$HOME/.local/bin"
export PATH="$BIN:$PATH"
mkdir -p "$BIN" "$HOME/.claude"

# 1) Ensure the CLI is present. It persists in the bind-mounted home dir and self-updates,
#    so this only does real work on first boot (or after a pinned-version bump).
#    CLAUDE_CODE_VERSION pins an exact version (incident rollback); otherwise we
#    track the channel (default: stable — ~1 week behind, skips regressions).
if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
  WANT="$CLAUDE_CODE_VERSION"
  export DISABLE_AUTOUPDATER=1
else
  WANT="${CLAUDE_CODE_CHANNEL:-stable}"
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "[entrypoint] Installing Claude Code ($WANT)…"
  curl -fsSL https://claude.ai/install.sh | bash -s "$WANT"
fi
echo "[entrypoint] Claude Code: $(claude --version 2>/dev/null || echo unknown)"

# 2) Pre-trust the workspace dir. GitOps deploys change auto-executing config
#    (.mcp.json, CLAUDE.md), which otherwise re-triggers the "trust this folder"
#    dialog on every restart and blocks the headless session. We control this
#    config, so mark the workspace trusted idempotently before launch.
CFG="$HOME/.claude.json"
[ -f "$CFG" ] || echo '{}' > "$CFG"
tmp="$(mktemp)"
jq --arg d "$HOME" '.projects[$d].hasTrustDialogAccepted = true' "$CFG" > "$tmp" && mv "$tmp" "$CFG"

# 3) Stable session name shown in the claude.ai remote-control picker.
SESSION="${REMOTE_CONTROL_SESSION:-claude-code-headless}"

# 4) Launch under tmux, stream the pane to the container log, keep PID 1 alive.
tmux kill-server 2>/dev/null || true
tmux new-session -d -s claude -x 220 -y 50 "claude --remote-control \"$SESSION\""
tmux pipe-pane -t claude -o 'cat >> /proc/1/fd/1' || true

echo "[entrypoint] Remote-control session '$SESSION' started."
echo "[entrypoint] Attach: kubectl exec -it <pod> -- tmux attach -t claude"

while tmux has-session -t claude 2>/dev/null; do
  sleep 15
done

echo "[entrypoint] tmux session ended; exiting so the pod can restart."
