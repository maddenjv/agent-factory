# The `agent` image every role runs (docker-compose.yml's `agent` service). Self-contained: no
# dependency on the sibling claude-code-sandbox repo. Only the toolchain and non-root user are
# reproduced here - not claude-code-sandbox's own entrypoint.sh, which every real invocation
# already overrides with bin/agent-loop.sh (see docker-compose.yml).
#
# bd is pulled with `go install ...@latest` (see docs/ARCHITECTURE.md "Dependency policy"); if
# `bd` CLI flags agent-loop.sh relies on ever drift, see README.md "Things I could not test" #3.

FROM golang:1.23-bookworm AS bd-builder
RUN CGO_ENABLED=0 go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest

FROM node:22-bookworm-slim

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG HOST_USER=agent

RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY --from=bd-builder /root/go/bin/bd /usr/local/bin/bd
RUN ln -s bd /usr/local/bin/beads

# node:22-bookworm-slim already ships a 'node' user/group at uid/gid 1000 (the default
# HOST_UID/HOST_GID). Drop it first so it can never collide with the account we create below,
# regardless of what HOST_UID/HOST_GID are set to.
RUN userdel -r node 2>/dev/null; groupdel node 2>/dev/null; \
    groupadd -g "$HOST_GID" "$HOST_USER" && useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash "$HOST_USER"

USER ${HOST_USER}
ENV HOME=/home/${HOST_USER}

CMD ["bash"]
