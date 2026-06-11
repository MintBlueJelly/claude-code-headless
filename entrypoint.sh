#!/usr/bin/env bash
# PID 1 of the claude-code pod.
#
# Installs/locates the Claude Code CLI on the bind-mounted home dir, then runs an
# interactive session (with Remote Control enabled) under tmux. Three concurrent
# clients share that one session:
#   * claude.ai pairs to it (outbound, no ingress required),
#   * ttyd serves it as an OIDC-gated web console on :7681, and
#   * `kubectl exec -it <pod> -- tmux attach -t claude` gives a live terminal.
# Session output is deliberately NOT streamed to the container log: a diagnostics
# agent routinely prints secrets, and `kubectl logs` would forward them to
# OpenObserve. Live view is the web console / tmux attach; conversation history is
# the persisted transcript on the PVC.
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

# 3) Stable session name shown in the claude.ai remote-control picker (display only).
SESSION="${REMOTE_CONTROL_SESSION:-claude-code-headless}"

# 4) Pin a fixed conversation UUID, persisted on the bind-mounted home dir, so the
#    SAME claude.ai remote session reconnects on every restart instead of a new
#    (orphaned) one being spawned. The remote session is keyed to the local session
#    id — not the display name — so a stable id is the only firm guarantee. First
#    boot (no id, or its transcript is gone) creates the conversation with
#    --session-id; later boots resume that exact id. Never --fork-session (mints a
#    new id) and never --continue (resumes whatever is *most recent*, which can
#    silently switch conversations).
SIDFILE="$HOME/.claude/remote-session-id"
PROJ="$HOME/.claude/projects/${HOME//\//-}"
SID=""
[ -f "$SIDFILE" ] && SID="$(cat "$SIDFILE")"
if [ -n "$SID" ] && [ -f "$PROJ/$SID.jsonl" ]; then
  MODE="--resume $SID"
  echo "[entrypoint] Resuming pinned session $SID."
else
  SID="$(cat /proc/sys/kernel/random/uuid)"
  echo "$SID" > "$SIDFILE"
  MODE="--session-id $SID"
  echo "[entrypoint] No prior transcript — creating pinned session $SID."
fi

# 5) Launch the interactive session under tmux with Remote Control, plus the ttyd
#    web console as a second client. On SIGTERM/SIGINT, tear the session down
#    cleanly so the server-side remote entry closes promptly (within
#    terminationGracePeriodSeconds) instead of lingering as a ghost.
cleanup() {
  echo "[entrypoint] Stopping web console and tmux session…"
  kill "${TTYD_PID:-}" 2>/dev/null || true
  tmux kill-session -t claude 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT

tmux kill-server 2>/dev/null || true
tmux new-session -d -s claude -x 220 -y 50 "claude $MODE --remote-control \"$SESSION\""
# Keep the pane at a fixed size (don't let a small web/exec client reflow it) and
# enable mouse mode so touchpad/wheel scrolling works instead of emitting cursor
# Up/Down keys (hold Shift for native terminal text selection).
tmux set-option -g window-size manual
tmux set-option -g mouse on

# Web console: another writable client of the same session. Interactive (-W);
# access is gated upstream by the OIDC HTTPRoute, so no ttyd-level auth here.
# titleFixed pins the browser tab title (else it shows the tmux attach command).
TITLE="${WEB_CONSOLE_TITLE:-Claude Code}"
ttyd -W -t "titleFixed=$TITLE" -p 7681 -i 0.0.0.0 tmux attach -t claude &
TTYD_PID=$!

echo "[entrypoint] Remote-control session '$SESSION' started (web console on :7681)."
echo "[entrypoint] Attach: kubectl exec -it <pod> -- tmux attach -t claude"

# Keep PID 1 alive while the session runs. `sleep & wait` (not a bare sleep) so a
# SIGTERM interrupts the wait promptly and the trap can run.
while tmux has-session -t claude 2>/dev/null; do
  sleep 15 &
  wait $!
done

cleanup
echo "[entrypoint] tmux session ended; exiting so the pod can restart."
