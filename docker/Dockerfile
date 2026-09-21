FROM node:22-bookworm-slim

# Tooling the agents need. Add your project's toolchain here (python, go, rust, ...).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq curl ca-certificates ripgrep procps less \
      python3 python3-pip python3-venv build-essential \
    && rm -rf /var/lib/apt/lists/*

# Pin these once you have a combination that works; bd is moving fast.
ARG CLAUDE_CODE_VERSION=latest
ARG BD_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @beads/bd@${BD_VERSION}

# --dangerously-skip-permissions refuses to run as root, so use an unprivileged user
# whose uid/gid match your host user (bind-mounted data must be writable by it).
ARG UID=1000
ARG GID=1000
RUN (userdel -r node 2>/dev/null || true) && (groupdel node 2>/dev/null || true) \
 && groupadd -g ${GID} agent \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash agent \
 && mkdir -p /work && chown agent:agent /work

USER agent
WORKDIR /work
ENTRYPOINT ["bash", "/work/bin/agent-loop.sh"]
