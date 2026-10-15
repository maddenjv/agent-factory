# Design: passwordless sudo for the agent user (agent-factory-eqy2)

Story: `docs/stories/agent-factory-eqy2.md`.

## Approach
Three coordinated changes; the container still runs as the non-root host-mapped user by default.

1. **Dockerfile**: install `sudo` and grant `$HOST_USER` passwordless sudo via a drop-in.
2. **docker-compose.yml** (`agent` service): relax the hardening just enough for a setuid `sudo` to
   work and for root to run `apt`/`dpkg`. Nothing else in the hardening block changes.
3. **Instructions + docs**: tell agents sudo exists and the rules for using it.

## 1. Dockerfile
- Add `sudo` to the existing first `apt-get install` list (same layer; no extra layer).
- After the `useradd` RUN (still as root, before `USER ${HOST_USER}`), add:
  ```
  RUN printf '%s\n' \
        "${HOST_USER} ALL=(ALL) NOPASSWD:ALL" \
        "Defaults:${HOST_USER} env_keep += \"http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY\"" \
        > /etc/sudoers.d/90-agent \
      && chmod 0440 /etc/sudoers.d/90-agent \
      && visudo -cf /etc/sudoers.d/90-agent
  ```
  `visudo -cf` fails the build on a malformed file. The `env_keep` line keeps apt working behind a
  proxy (sudo otherwise resets the environment). Do not add the user to a `sudo` group; the drop-in
  is the single source of truth. Works identically for both `HARNESS` values (the harness install
  layer is untouched).
- `USER`, `HOME`, `CMD` unchanged: default user stays non-root (AC5).

## 2. docker-compose.yml hardening change
Why the current block breaks sudo: `sudo` is setuid-root, and `no-new-privileges:true` makes the
kernel ignore setuid, so it can never gain root; `cap_drop: [ALL]` would additionally leave root
unable to `setuid`/`chown`.

Replace
```
cap_drop: [ALL]
security_opt: ["no-new-privileges:true"]
```
with
```
cap_drop: [ALL]
cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, FSETID, SETUID, SETGID, KILL, AUDIT_WRITE]
```
and **remove** the `security_opt` line (no-new-privileges cannot coexist with sudo; there is no
narrower alternative). Update the comment above the block to say so. Keep `pids_limit: 512`,
`mem_limit: 6g`, the volume list (no docker socket, no `~/.ssh`, `:ro` host-config and kit mounts)
exactly as is.

Capability rationale (all are inside the container's bounding set only; this is a strict subset of
Docker's default set, minus `NET_RAW`, `NET_BIND_SERVICE`, `MKNOD`, `SETFCAP`, `SETPCAP`,
`SYS_CHROOT`):
- `SETUID`, `SETGID`: sudo switching to uid 0; apt dropping to `_apt`.
- `CHOWN`, `FOWNER`, `FSETID`, `DAC_OVERRIDE`: dpkg unpacking/chmod/chown of package files.
- `KILL`: some maintainer scripts signal daemons.
- `AUDIT_WRITE`: sudo/PAM audit message; absent, sudo logs a noisy error.
Because the set is the bounding set, root in the container is still without `SYS_ADMIN`, `NET_ADMIN`,
`SYS_PTRACE`, `MKNOD`, raw sockets, etc. `:ro` bind mounts are enforced at mount level and root
cannot remount without `SYS_ADMIN`, so read-only host mounts stay read-only.

**Engineer verification note**: the list above is the design's intent; confirm empirically that
`sudo -n apt-get update && sudo -n apt-get install -y tree` works with it. If a capability is
provably unnecessary (try removing `KILL`, `FSETID`, `AUDIT_WRITE` one at a time) drop it; if
something fails on a missing capability, add only that one and note it in the compose comment and
ARCHITECTURE.md. Do not widen beyond Docker's default set. If an unavoidable need arises
beyond it, stop and `needs-team-lead`.

Residual risk to document: files written by root under the read-write project bind mount are
root-owned on the host. Instructions tell agents not to use sudo for writes in their clone.

## 3. Instructions
Add a section "## Container & sudo" (same wording in all three) to: `agents/CLAUDE.project.md`
(the template copied into projects), and the repo-root `CLAUDE.md` and `AGENTS.md` (mirrored per the
Beads note; insert after "## Git"/before "## Files"; in `AGENTS.md`/`CLAUDE.md` put it above the
managed Beads block, never inside the `BEGIN/END BEADS INTEGRATION` markers). Text:

> ## Container & sudo
> - You run as a non-root user in a container with passwordless `sudo` (`sudo -n ...`). Installing
>   packages the assigned issue needs (`sudo apt-get update && sudo apt-get install -y <pkg>`) is allowed.
> - Use it only to make the assigned work build, run or test. Do not use it to change the
>   container's security settings, mounts or credentials, or to touch anything outside your clone
>   (and, for installs, the system package paths). Do not use sudo to write into your clone: it
>   would leave root-owned files on the host.
> - The container is not persistent: installs vanish on rebuild/restart. If the project needs a
>   package permanently, file an issue (`discovered-from` your current one) to add it to the
>   `Dockerfile`; do not rely on an install you made.

Also add a one-line pointer ("Passwordless `sudo` is available - see CLAUDE.md 'Container & sudo'.")
to `agents/engineer.md` and `agents/qa.md` (roles that build/run things), so the role-prompt text
mentions it too. No changes to other role prompts.

## 4. Docs
- `docs/ARCHITECTURE.md`, Stack -> `agent` bullet: state the agent user has passwordless sudo
  (`/etc/sudoers.d/90-agent`), root-in-container is confined by the retained controls, and describe
  the hardening delta: `no-new-privileges` removed, `cap_drop: ALL` + the explicit `cap_add`
  list; unchanged: no docker socket, no `~/.ssh`, `pids_limit`, `mem_limit`, `:ro` mounts.
- `README.md` "Security notes": add a bullet with the same facts (sudo exists; what was relaxed and
  why; runtime installs are ephemeral). Do not change the existing "nothing sensitive is mounted" text.

## Error cases
- Malformed sudoers -> build fails at `visudo -cf` (intended).
- Operator running the container with their own `--cap-drop`/`no-new-privileges` override: sudo
  prints "effective uid is not 0" / "no new privileges"; not supported, covered by the README bullet.
- No network: `apt-get` fails normally; not a design concern.

## Acceptance criteria mapping
1-2: sudoers drop-in + setuid sudo permitted (NNP removed, SETUID/SETGID). 3: apt caps + env_keep.
4: Dockerfile change is harness-independent; build with both `--build-arg HARNESS=`. 5: `USER`
unchanged; non-sudo writes stay host-user owned. 6: compose block diff touches only the two
lines. 7-8: instruction section. 9: docs.

## Test strategy (QA)
Put in `tests/agent-factory-eqy2_test.sh`, in the style of the existing tests/ scripts.
- **Static** (no docker needed): `docker compose config` (or grep) shows `cap_drop` ALL, `cap_add` has
  SETUID and SETGID, no `no-new-privileges`, `pids_limit`/`mem_limit` present, no `docker.sock`/`.ssh`
  in volumes, host-config mounts `:ro`; Dockerfile contains the sudoers drop-in with `visudo -c`;
  the three instruction files contain the "Container & sudo" section with `sudo`, "install",
  "Dockerfile"/issue wording, and the "not persistent" caveat; `AGENTS.md` and `CLAUDE.md` mirror it;
  ARCHITECTURE.md and README mention passwordless sudo.
- **Runtime** (skip with a clear message if docker/build unavailable): build the image (default and
  `HARNESS=copilot`); in `docker compose run --rm --entrypoint bash agent -lc`: `sudo -n true`;
  `sudo -n id -u` = `0`; `id -u` != 0; `sudo -n apt-get update && sudo -n apt-get install -y tree && tree --version`;
  `claude`/`copilot`, `bd`, `git`, `jq`, `curl`, `shellcheck` all `--version`; no `/var/run/docker.sock`,
  no `~/.ssh`; `/proc/self/status` shows pids limit via cgroup (`cat /sys/fs/cgroup/pids.max` = 512);
  `touch` on a `:ro` mount fails, even under `sudo`; a file touched in the bind-mounted workspace is
  owned by `$HOST_UID`.
- Regression: existing `tests/` scripts, `bin/check-tests.sh`.
