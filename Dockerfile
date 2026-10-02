# The `agent` image every role runs (docker-compose.yml's `agent` service). Self-contained: no
# dependency on the sibling claude-code-sandbox repo. Only the toolchain and non-root user are
# reproduced here - not claude-code-sandbox's own entrypoint.sh, which every real invocation
# already overrides with bin/agent-loop.sh (see docker-compose.yml).
#
# bd is pulled with `go install ...@latest` (see docs/ARCHITECTURE.md "Dependency policy"); if
# `bd` CLI flags agent-loop.sh relies on ever drift, see README.md "Things I could not test" #3.

FROM golang:bookworm AS bd-builder
RUN CGO_ENABLED=0 go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest

FROM node:bookworm-slim

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG HOST_USER=agent
ARG HARNESS=claude-code

RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq curl ca-certificates shellcheck \
    && rm -rf /var/lib/apt/lists/*

# Operator-supplied extra CA certificates (docs/ARCHITECTURE.md "Extra CA certificates").
COPY extra-ca/ /tmp/extra-ca/
RUN set -eu; \
    found=0; \
    for f in /tmp/extra-ca/* /tmp/extra-ca/.[!.]*; do \
      [ -e "$f" ] || continue; \
      name=$(basename "$f"); \
      [ "$name" = .gitkeep ] && continue; \
      case "$name" in \
        *.crt) ;; \
        *) echo "error: extra-ca/$name: only PEM files named *.crt are accepted (rename it, or remove it)" >&2; exit 1 ;; \
      esac; \
      if ! grep -q 'BEGIN CERTIFICATE' "$f" || ! openssl x509 -in "$f" -noout >/dev/null 2>&1; then \
        echo "error: extra-ca/$name is not a valid PEM certificate" >&2; exit 1; \
      fi; \
      mkdir -p /usr/local/share/ca-certificates/extra; \
      cp "$f" "/usr/local/share/ca-certificates/extra/$name"; \
      found=1; \
    done; \
    if [ "$found" = 1 ]; then update-ca-certificates; fi; \
    rm -rf /tmp/extra-ca
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

RUN case "$HARNESS" in \
      claude-code) npm install -g @anthropic-ai/claude-code ;; \
      copilot) npm install -g @github/copilot ;; \
      *) echo "error: unknown HARNESS '$HARNESS' (expected claude-code or copilot)" >&2; exit 1 ;; \
    esac

COPY --from=bd-builder /go/bin/bd /usr/local/bin/bd
RUN ln -s bd /usr/local/bin/beads

# node:22-bookworm-slim already ships a 'node' user/group at uid/gid 1000 (the default
# HOST_UID/HOST_GID). Drop it first so it can never collide with the account we create below,
# regardless of what HOST_UID/HOST_GID are set to.
RUN userdel -r node 2>/dev/null; groupdel node 2>/dev/null; \
    groupadd -g "$HOST_GID" "$HOST_USER" && useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash "$HOST_USER"

USER ${HOST_USER}
COPY --chown=${HOST_UID}:${HOST_GID} dotfiles/ /home/${HOST_USER}/
RUN rm -f /home/${HOST_USER}/.gitkeep
ENV HOME=/home/${HOST_USER}

CMD ["bash"]
