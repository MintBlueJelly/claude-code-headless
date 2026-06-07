# Bump IMAGE_VERSION when the base image / baked tooling changes.
# Claude Code itself is NOT baked in: it is installed at runtime into the
# bind-mounted home dir (see entrypoint.sh) and self-updates from there, so a
# new CLI release does not require an image rebuild.
ARG IMAGE_VERSION="1.0.0"
ARG KUBECTL_VERSION="1.35.2"
ARG TALOSCTL_VERSION="1.12.4"

# --- Build gitea-mcp (Go) ----------------------------------------------------
FROM docker.io/golang:1.26-bookworm AS gitea-mcp
RUN go install gitea.com/gitea/gitea-mcp@latest

# --- Build technitium-mcp (TypeScript -> dist) -------------------------------
FROM docker.io/node:24-bookworm AS technitium-mcp
RUN git clone --depth 1 https://github.com/rosschurchill/technitium-mcp-secure.git /src
WORKDIR /src
RUN npm ci && npm run build

# --- Final image -------------------------------------------------------------
FROM docker.io/node:24-bookworm
ARG KUBECTL_VERSION
ARG TALOSCTL_VERSION

# Runtimes the MCP servers need: node/npx (kubernetes, technitium), python+uv
# (unifi plugin), git/gh (repo clones), plus cluster CLIs (kubectl, talosctl,
# omnictl) for hands-on diagnostics and the remote-control session glue.
# --retry guards against transient 403/429/5xx from GitHub release downloads.
RUN CURL="curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 10" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg2 jq less procps python3 python3-venv \
        ripgrep tmux unzip \
    && $CURL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && $CURL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl \
    && $CURL "https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}/talosctl-linux-amd64" \
        -o /usr/local/bin/talosctl && chmod +x /usr/local/bin/talosctl \
    && $CURL "https://github.com/siderolabs/omni/releases/latest/download/omnictl-linux-amd64" \
        -o /usr/local/bin/omnictl && chmod +x /usr/local/bin/omnictl \
    && $CURL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && rm -rf /var/lib/apt/lists/*

# Baked MCP servers
COPY --from=gitea-mcp /go/bin/gitea-mcp /usr/local/bin/gitea-mcp
COPY --from=technitium-mcp /src/dist /opt/technitium-mcp/dist
COPY --from=technitium-mcp /src/node_modules /opt/technitium-mcp/node_modules

# Org policy: highest-precedence managed settings (lock bypass mode, etc.)
RUN mkdir -p /etc/claude-code
COPY managed-settings.json /etc/claude-code/managed-settings.json

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Non-root user; home is bind-mounted at runtime. The node base image already
# ships a user/group at 1000, so reuse it: rename node -> claude and move its
# home to /home/claude (keeps UID/GID 1000 for the pod securityContext).
RUN groupmod -n claude node \
    && usermod -l claude -d /home/claude -m node
USER claude
WORKDIR /home/claude
ENV HOME=/home/claude \
    PATH=/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin \
    CLAUDE_CODE_CHANNEL=stable

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
