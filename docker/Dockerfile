# syntax=docker/dockerfile:1
# fr-workflow autopilot — one container that keeps a repository's autopilot
# alive: Claude Code, gh, git, jq and a Chromium for the Playwright MCP server,
# run as the unprivileged user the Playwright image ships. Nothing project-
# specific is baked in: the repository, its profile and the pinned plugin
# arrive at runtime (see docs/container.md).
#
#   docker build -t fr-workflow-autopilot docker/
#   docker build --build-arg CLAUDE_CODE_VERSION=2.1.320 -t fr-workflow-autopilot docker/
ARG PLAYWRIGHT_VERSION=1.65.0
FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble

ARG CLAUDE_CODE_VERSION=2.1.319
ARG GH_VERSION=2.103.3

# gh from its release package, checksum verified; jq for the entrypoint and
# fr.sh; tini reaps the background sessions' processes.
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends jq tini ca-certificates curl git bash xvfb; \
    rm -rf /var/lib/apt/lists/*; \
    arch=$(dpkg --print-architecture); \
    cd /tmp; \
    curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.deb"; \
    curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"; \
    sha256sum --ignore-missing -c "gh_${GH_VERSION}_checksums.txt"; \
    dpkg -i "gh_${GH_VERSION}_linux_${arch}.deb"; \
    rm -f /tmp/gh_*

# Claude Code, pinned: the npm package installs the native binary. Updates are
# off — a newer Claude Code is a new image, built and tested like any change.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && claude --version
ENV DISABLE_AUTOUPDATER=1

COPY entrypoint.sh /usr/local/bin/fr-autopilot
RUN chmod 0755 /usr/local/bin/fr-autopilot

# pwuser (uid 1001) comes with the Playwright image. Everything that must
# survive a restart lives in its home: Claude Code's state and sessions
# (~/.claude, ~/.claude.json), the clones (~/work/<repo>), npm's cache.
# `docker exec` lands in ~/work, which the entrypoint trusts, so
# `claude attach` and `claude agents` work from there without a dialog.
USER pwuser
ENV HOME=/home/pwuser
WORKDIR /home/pwuser/work
VOLUME ["/home/pwuser"]

# xvfb-run gives the Playwright MCP server a display: the plugin starts the
# browser headed, so the user can watch on a laptop; in the container the
# virtual display takes that role and nothing in the plugin changes.
ENTRYPOINT ["tini", "--", "xvfb-run", "-a", "/usr/local/bin/fr-autopilot"]
CMD ["run"]
