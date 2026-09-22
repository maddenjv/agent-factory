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

RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY --from=bd-builder /root/go/bin/bd /usr/local/bin/bd
RUN ln -s bd /usr/local/bin/beads

RUN groupadd -g "$HOST_GID" john && useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash john

USER john
ENV HOME=/home/john

CMD ["bash"]
