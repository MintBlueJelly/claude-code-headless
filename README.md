# claude-code-headless

A long-running [Claude Code](https://code.claude.com) workload for container
deployments. It runs the CLI as an interactive session with **Remote Control**
enabled (`claude --remote-control <session>`), which dials _out_ to Anthropic so
the session can be driven from the `claude.ai` web app — and the same session is
also reachable through an in-cluster **web console** (ttyd) and `tmux attach`.

This image is built for homelab diagnostics and operations and includes a number
of MCP servers, plugins, and CLIs tailored to my specific requirements (Kubernetes,
Talos, Omni, Home Assistant, OpenObserve, UniFi, Technitium, Gitea).

## Requirements

- **A claude.ai subscription** (Pro/Max/Team/Enterprise). Remote Control rejects
  API keys and `setup-token` — see [Authentication](#authentication-one-time-interactive).
- **amd64 / x86_64 only.** The baked CLIs (`kubectl`, `talosctl`, `omnictl`, `ttyd`)
  are amd64 binaries; the image does **not** run on arm64 (Apple Silicon, Raspberry
  Pi, Graviton).
- **A persistent volume** for `/home/claude` (the CLI, credentials, and conversation
  history live there — see the [runtime contract](#runtime-contract)).

## Design notes

- **Claude Code is not baked into the image.** `entrypoint.sh` installs it via
  `https://claude.ai/install.sh` into the bind-mounted home dir on first boot and
  lets it self-update. A new CLI release therefore needs **no image rebuild**.
  Pin with `CLAUDE_CODE_VERSION` for incident rollback (sets
  `DISABLE_AUTOUPDATER=1`); otherwise it tracks `CLAUDE_CODE_CHANNEL` (default
  `stable`).
- **tmux wrapper + web console.** The CLI runs inside one tmux session that
  several clients share concurrently: `claude.ai` (remote-control), a **ttyd web
  console** on port `7681`, and `kubectl exec -it <pod> -- tmux attach -t claude`.
  Session output is **not** streamed to the container log — a diagnostics agent
  prints secrets, and `kubectl logs` would forward them to a log backend; live
  view is the web console / tmux attach, history is the PVC transcript. The web
  console is writable and gives a real terminal in the pod (a tmux client can spawn
  a shell), so it **must** be exposed only behind admin-restricted auth (OIDC).
- **Stable session identity.** `entrypoint.sh` pins a fixed conversation UUID
  persisted at `~/.claude/remote-session-id` and resumes it (`--resume <uuid>`) on
  every restart, creating it once with `--session-id` on first boot. This keeps the
  _same_ claude.ai remote session reconnecting across restarts instead of spawning a
  new, orphaned conversation each time.
- **Baked MCP runtimes/servers:** node 24/npx, python3 + `uv` (unifi plugin),
  `gitea-mcp` (Go), `technitium-mcp` (built from
  [rosschurchill/technitium-mcp-secure](https://github.com/rosschurchill/technitium-mcp-secure)).
- **Baked cluster CLIs:** `kubectl`, `talosctl`, `omnictl`, plus `git`, `gh`.
- **Managed settings** at `/etc/claude-code/managed-settings.json` lock the
  permission posture (bypass-permissions disabled) and auto-approve project MCP
  servers so the cluster `.mcp.json` loads without prompting.

## Runtime env vars

| Var                      | Default                | Purpose                                    |
| ------------------------ | ---------------------- | ------------------------------------------ |
| `CLAUDE_CODE_CHANNEL`    | `stable`               | release channel when no version is pinned  |
| `CLAUDE_CODE_VERSION`    | _(unset)_              | pin an exact version; disables auto-update |
| `REMOTE_CONTROL_SESSION` | `claude-code-headless` | session name in the claude.ai picker       |
| `GH_TOKEN`               | _(unset)_              | GitHub API access for the `gh` CLI         |
| `TZ`                     | _(unset)_              | container timezone, e.g. `Europe/Berlin`   |

Beyond `GH_TOKEN`, the agent reads whatever MCP/CLI tokens your `.mcp.json`
references (e.g. `GITEA_ACCESS_TOKEN`, `OPENOBSERVE_TOKEN`, `TECHNITIUM_*_TOKEN`,
`UNIFI_NETWORK_*`); inject them however your platform handles secrets.

## Usage

### Quick start (Docker)

```bash
docker run -d --name claude-code \
  -v claude-code-home:/home/claude \      # named vol: inherits the image's 1000:1000 ownership
  -p 127.0.0.1:7681:7681 \                # web console — keep off untrusted networks (see below)
  -e CLAUDE_CODE_CHANNEL=latest \
  ghcr.io/mintbluejelly/claude-code-headless:latest

# First run only: authenticate and trust the workspace (see Authentication)
docker exec -it claude-code tmux attach -t claude
```

Use a **named volume** (not a host bind mount): a fresh named volume inherits the
image's `/home/claude` ownership (UID/GID 1000), so the non-root user can write to
it; a host bind mount would be root-owned and break first boot unless you pre-chown
it. To enforce the permission posture, also mount your own settings read-only:
`-v ./managed-settings.json:/etc/claude-code/managed-settings.json:ro`.

### Runtime contract

Any orchestrator (Kubernetes, Podman, Nomad, …) must satisfy the same contract:

- **Persistent volume at `/home/claude`**, owned by UID/GID **1000** — it holds the
  CLI install, `~/.claude/.credentials.json`, the pinned `remote-session-id`, and
  the conversation transcript. It must survive restarts.
- **Runs as non-root UID/GID 1000**; no privilege escalation or extra capabilities
  are needed.
- **Web console on container port `7681`** (plain HTTP, **no built-in auth**). Front
  it with an authenticating proxy / OIDC ingress; never expose it raw.
- **Never set `ANTHROPIC_API_KEY`** — it blocks Remote Control. Auth is the
  interactive claude.ai login on first boot.
- _Optional:_ mount a `managed-settings.json` at
  `/etc/claude-code/managed-settings.json` to enforce the permission posture.
- _Optional:_ mount your own `~/.mcp.json` (plus the tokens it references). The image
  bakes the MCP **runtimes/servers** but **not** an MCP config — without a
  `.mcp.json`, none of them load.

The reference deployment is a Kustomize **StatefulSet** (in my gitops repo): a PVC
for `/home/claude`, a ConfigMap supplying `managed-settings.json` / `.mcp.json` /
`CLAUDE.md`, and an OIDC-protected HTTPRoute fronting port 7681.

### First-run plugin setup

The UniFi plugin must be installed manually once, from inside the session:

```text
/plugin marketplace add sirkirby/unifi-mcp
/plugin install unifi-network@unifi-plugins
/unifi-network:setup # only required if ENV vars for auto-setup are not set
```

## Authentication (one-time, interactive)

Remote Control requires a **claude.ai subscription** OAuth login and rejects
API keys / `setup-token` (`CLAUDE_CODE_OAUTH_TOKEN`). Do **not** set
`ANTHROPIC_API_KEY` — if present it blocks Remote Control. Authenticate once
into the persisted home volume by attaching to the session:

```bash
docker exec -it claude-code tmux attach -t claude
# or, on Kubernetes:
kubectl exec -it claude-code-0 -- tmux attach -t claude
```

In the session, choose the claude.ai subscription option, open the printed URL in a
browser, paste the returned code, then accept the workspace-trust dialog. Detach
with `Ctrl-b d`.

The resulting `~/.claude/.credentials.json` lives on the volume and auto-refreshes,
so this survives restarts.

## Build

CI builds and pushes to `ghcr.io/mintbluejelly/claude-code-headless` on push to
`main` (see `.github/workflows/docker-image.yml`). The image version is derived
automatically from git history via Conventional Commits (`feat` → minor,
`fix` → patch, `feat!` / `BREAKING CHANGE` → major) — there is **no** manual version
bump. Base-image or baked-tooling changes ride the normal commit → tag flow.

## License

Released under the [MIT License](LICENSE).
