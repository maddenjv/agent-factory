# Design: additional CA certificates in the agent image (agent-factory-5njf)

Story: `docs/stories/agent-factory-5njf.md`. Only the `agent` image (`Dockerfile`) changes.

## Approach
Operator drops PEM files named `*.crt` into `extra-ca/` (repo root, contents git-ignored). The
`Dockerfile` copies that directory into the image, validates every file, installs them with
Debian's `update-ca-certificates`, and sets `NODE_EXTRA_CA_CERTS`. No compose/script changes: the
`agent` service's build context is already `.`, and `docker compose build agent` is already the
rebuild step.

## Files
1. **`extra-ca/.gitkeep`** (new, tracked, empty). The directory must exist in every checkout,
   otherwise `COPY extra-ca/` fails and AC1 regresses.
2. **`.gitignore`**: add
   ```
   # Operator-supplied extra CA certs for the agent image (see docs/ARCHITECTURE.md)
   extra-ca/*
   !extra-ca/.gitkeep
   ```
   (`extra-ca/` itself must not be ignored, or the `!` re-include does not work.) Satisfies AC6.
3. **`Dockerfile`**: in the final stage, directly after the `apt-get install ... ca-certificates`
   RUN and before the `npm install` RUN (so a CA is also trusted by npm at build time behind an
   intercepting proxy; the `bd-builder` stage is NOT changed - see Non-goals), as root:
   ```dockerfile
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
         if ! openssl crl2pkcs7 -nocrl -certfile "$f" 2>/dev/null | openssl pkcs7 -print_certs -noout >/dev/null 2>&1; then \
           echo "error: extra-ca/$name is not a valid PEM certificate" >&2; exit 1; \
         fi; \
         mkdir -p /usr/local/share/ca-certificates/extra; \
         cp "$f" "/usr/local/share/ca-certificates/extra/$name"; \
         found=1; \
       done; \
       if [ "$found" = 1 ]; then update-ca-certificates; fi; \
       rm -rf /tmp/extra-ca
   ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
   ```
   Decisions:
   - **Validation via `openssl`** (a dependency of the `ca-certificates` package, so already
     present). Engineer: verify empirically that (a) a garbage file, (b) an empty file, (c) a
     private key PEM, and (d) a valid single cert and a multi-cert bundle give the right
     pass/fail; if the pkcs7 pipeline misbehaves, fall back to `openssl x509 -in "$f" -noout`
     (single-cert files only) - but the error text must keep naming the file (AC5).
   - **Non-`*.crt` files fail the build** (other than `.gitkeep`) rather than being silently
     ignored: `update-ca-certificates` only picks up `.crt`, so a `corp.pem` would otherwise be
     skipped without notice, which is exactly the failure mode AC5 objects to.
   - **Nothing supplied** -> no `update-ca-certificates` run, no files written: trust store is
     byte-identical to the base layer (AC1).
   - **`NODE_EXTRA_CA_CERTS` points at the system bundle** rather than a separate file: it always
     exists (a Dockerfile `ENV` cannot be conditional, and node warns on a missing file), and it
     contains the extras after `update-ca-certificates`. When nothing is supplied it only
     duplicates roots node already has - harmless. `git`, `curl` and Go (`bd`) read
     `/etc/ssl/certs` by default, so need nothing else (AC3).
   - **Removal (AC7)** works through normal Docker layer caching: the `COPY` layer is keyed on the
     directory content, so deleting a file re-runs the RUN from the clean apt layer; there is no
     state carried over. No `--no-cache` needed.
4. **`docs/ARCHITECTURE.md`**: in the `agent` bullet under Stack (or a short "Extra CA
   certificates" paragraph right after it) document: purpose; put `*.crt` PEM files in
   `extra-ca/` (git-ignored; never commit them); rebuild with `docker compose build agent`
   (via `dc()` / `bin/` as usual), then restart agents; removing a file and rebuilding removes the trust;
   invalid or non-`*.crt` files fail the build naming the file; `NODE_EXTRA_CA_CERTS`; runtime
   injection is out of scope. Also add `extra-ca/` to the Layout tree. Optionally one line in
   README's setup section pointing at that paragraph.

## Error cases
| Case | Result |
|---|---|
| `extra-ca/` has only `.gitkeep` | build as before |
| `*.crt` is not valid PEM / empty / a key | build fails, `error: extra-ca/<name> is not a valid PEM certificate` |
| non-`*.crt` file (e.g. `.pem`, `.cer`) | build fails naming it, hint to rename |
| multiple certs / bundle in one `.crt` | accepted (all installed; `update-ca-certificates` splits bundles) |
| `extra-ca/` directory deleted from checkout | `COPY` fails with Docker's "not found" error; restore with `mkdir extra-ca && touch extra-ca/.gitkeep` (mention in ARCHITECTURE.md) |

## Acceptance criteria mapping
1. No files -> guarded no-op; QA compares `sha256sum /etc/ssl/certs/ca-certificates.crt` of an image built with and without the `extra-ca` step (or against `node:bookworm-slim` after the same apt step).
2. Install to `/usr/local/share/ca-certificates/extra/` + `update-ca-certificates` -> bundle contains the cert.
3. System bundle -> `curl`, `git` work as the agent user, no flags.
4. `NODE_EXTRA_CA_CERTS` set in image ENV (visible to `docker run` and the compose entrypoint alike).
5. Validation loop above.
6. `.gitignore` entry + ARCHITECTURE.md section.
7. Layer-cache behaviour above.

## Non-goals
- `bd-builder` stage (`go install`) does not get the extra CAs; build-time Go module fetching behind
  an intercepting proxy is not in the story. If wanted, file a follow-up.
- Runtime mounting, rotation, mTLS, proxy config, other service images (per story).

## Test strategy (QA)
Acceptance-style shell script `tests/agent-factory-5njf_test.sh`, in the style of the existing ones.
Don't touch the operator's real `extra-ca/` or the `factory-agent:latest` tag: copy the repo's
`Dockerfile` + `extra-ca/` (+ `dotfiles/` if the build needs it) into a temp dir and
`docker build -t factory-agent-5njf-test <tmp>`; clean up with a trap. Generate a throwaway CA and a
`localhost` leaf with SAN using `openssl` in the test.
- **Static (fast, no Docker)**: `.gitignore` ignores `extra-ca/x.crt` but not `extra-ca/.gitkeep`
  (`git check-ignore`); `.gitkeep` is tracked; ARCHITECTURE.md mentions `extra-ca`.
- **Build (Docker; skip with a clear message if Docker unavailable)**: AC1 (empty dir, build ok,
  bundle hash equals baseline); AC2 (cert present in bundle, e.g. compare the PEM body);
  AC5 (garbage `bad.crt` and a `foo.pem` each fail the build with the filename in the output);
  AC7 (rebuild after removing the cert: absent).
- **Runtime (Docker)**: run `openssl s_server -www` with the leaf cert inside the container (or on
  the host, `--network host`) and assert as the agent user `curl https://localhost:<port>/` and
  `git ls-remote https://localhost:<port>/x.git` get past TLS (git may then fail on the HTTP
  response; assert the error is not a certificate error); control: same commands against a build
  without the CA fail with a certificate error. AC4: `docker run ... printenv NODE_EXTRA_CA_CERTS`
  is set and a `node -e 'https.get(...)'` against the test server succeeds.
- Regression: existing `tests/` scripts, plus `shellcheck` is n/a (no bash script changed).
