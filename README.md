# claude-code-remote

A long-running [Claude Code](https://code.claude.com) workload for container
deployments. It runs the CLI in **remote-control mode** (`claude --remote-control <session>`),
which dials _out_ to Anthropic so the session can be driven from the `claude.ai`
web app on any browser.

This image is built for homelab diagnostics and operations and includes a number
of MCP servers, plugins, and CLIs tailored to my specific requirements (Kubernetes,
Talos, Omni, Home Assistant, OpenObserve, UniFi, Technitium, Gitea).

## Design notes

- **Claude Code is not baked into the image.** `entrypoint.sh` installs it via
  `https://claude.ai/install.sh` into the bind-mounted home dir on first boot and
  lets it self-update. A new CLI release therefore needs **no image rebuild**.
  Pin with `CLAUDE_CODE_VERSION` for incident rollback (sets
  `DISABLE_AUTOUPDATER=1`); otherwise it tracks `CLAUDE_CODE_CHANNEL` (default
  `stable`).
- **tmux wrapper.** The CLI runs inside tmux so the live session is reachable
  with `kubectl exec -it <pod> -- tmux attach -t claude`, while the pane is
  streamed to the container log for `kubectl logs`.
- **Baked MCP runtimes/servers:** node 24/npx, python3 + `uv` (unifi plugin),
  `gitea-mcp` (Go), `technitium-mcp` (built from
  [rosschurchill/technitium-mcp-secure](https://github.com/rosschurchill/technitium-mcp-secure)).
- **Baked cluster CLIs:** `kubectl`, `talosctl`, `omnictl`, plus `git`, `gh`.
- **Managed settings** at `/etc/claude-code/managed-settings.json` lock the
  permission posture (bypass-permissions disabled) and auto-approve project MCP
  servers so the cluster `.mcp.json` loads without prompting.

## Runtime env vars

| Var                       | Default                | Purpose                                       |
| ------------------------- | ---------------------- | --------------------------------------------- |
| `REMOTE_CONTROL_SESSION`  | `claude-code-headless` | session name in the claude.ai picker          |
| `CLAUDE_CODE_CHANNEL`     | `stable`               | release channel when no version is pinned     |
| `CLAUDE_CODE_VERSION`     | _(unset)_              | pin an exact version; disables auto-update    |
| `CLAUDE_CODE_OAUTH_TOKEN` | _(secret)_             | headless auth; mint with `claude setup-token` |
| `GH_TOKEN`                | _(unset)_              | for GitHub API access in `gh` CLI             |

## Build

CI builds and pushes to `ghcr.io/<owner>/claude-code-headless` on push to `main`
(see `.github/workflows/docker-image.yml`). Bump `ARG IMAGE_VERSION` in the
Dockerfile when the base image or baked tooling changes.

## Usage

The Unifi plugin needs to be installed and configured manually on first run (credentials are pulled from ENV variables):

```bash
/plugin marketplace add sirkirby/unifi-mcp
/plugin install unifi-network@unifi-plugins
/unifi-network:setup
```
