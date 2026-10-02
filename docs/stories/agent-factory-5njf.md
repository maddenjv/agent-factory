# agent-factory-5njf: Support additional CA certificates in the agent image

## Story
As a factory operator behind a TLS-intercepting proxy or using an internal registry/git host with a
private CA, I want to supply extra CA certificates that the `agent` image trusts, so that agents can
reach those hosts over HTTPS without disabling certificate verification.

## Context
The `agent` image is built from this repo's `Dockerfile` (`docker compose build agent`) and only
trusts the Debian base image's CA bundle. Tools the agents run (`git`, `curl`, `claude`/node, `bd`
and Go-built tools) fail with certificate errors against hosts signed by a private CA. Operators need
a way to add CAs without editing the Dockerfile. The mechanism is operator-supplied PEM files placed in a
dedicated directory in the repo checkout (git-ignored, so private certs are never committed) and
baked in when the image is built. When no extra CAs are supplied the build must behave exactly as today.

## Acceptance criteria
1. Given no extra CA files are supplied, when `docker compose build agent` runs, then the build
   succeeds and the image's trust store is identical to the base image's (no regression).
2. Given one or more PEM certificate files (`*.crt`) in the extra-CA directory, when the image is
   built, then each certificate is present in the image's system trust store
   (`/etc/ssl/certs/ca-certificates.crt` contains it).
3. Given a server presenting a certificate signed by a supplied extra CA, when `curl` and `git`
   (HTTPS) run in the container as the agent user, then they succeed without `-k` / `sslVerify=false`.
4. Given the same setup, when node-based tools (`claude`) run in the container, then they also trust
   the extra CA (i.e. `NODE_EXTRA_CA_CERTS` or equivalent points at the added certificates).
5. Given a file in the extra-CA directory that is not a valid PEM certificate, when the image is
   built, then the build fails with a message naming the offending file (rather than silently skipping it).
6. Given certificates in the extra-CA directory, when `git status` is run in the repo, then they are
   not shown as untracked (directory is git-ignored); the directory's purpose and the
   rebuild step are documented in `docs/ARCHITECTURE.md`.
7. Given an extra CA was added, when an operator removes it and rebuilds, then the certificate is no
   longer trusted in the image.

## Out of scope
- Runtime (mount-at-start) CA injection without rebuilding the image.
- Certificate rotation/expiry monitoring, client certificates (mTLS), per-tool CA configuration.
- Proxy configuration (HTTP(S)_PROXY) itself.
- Changing the `ollama`/other non-`agent` service images.
