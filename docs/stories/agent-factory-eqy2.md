# agent-factory-eqy2: passwordless sudo for the agent user

## Story
As an agent-factory operator, I want the non-root agent user in the `agent` container to have
passwordless sudo, and the agents' instructions to say so, so that agents can install the packages
a project needs (apt, system libraries, extra tools) themselves instead of stalling on a missing
dependency.

## Context
The `agent` image runs as a non-root user built from the host user (`HOST_USER`/`HOST_UID`/
`HOST_GID`). That user has no way to become root, so any `apt-get install` fails. Related story
agent-factory-ncij pre-installs common language toolchains; this story covers everything it
doesn't. The agent instructions (`CLAUDE.md` / `agents/CLAUDE.project.md` and the role prompts)
currently say nothing about sudo or runtime package installs.

Note for design: `docker-compose.yml` hardens the `agent` service with `cap_drop: [ALL]` and
`no-new-privileges:true`, which will prevent sudo from working. How to relax that, and how much, is
a design decision. Whatever is relaxed must stay as narrow as practical, and the remaining
hardening (no docker socket, no `~/.ssh`, pids/memory limits, read-only host-config mounts) must be
preserved. Root inside the container is acceptable only because the container itself stays
confined.

## Acceptance criteria
1. Given a freshly built `agent` image, when the non-root agent user runs `sudo -n true`, then it
   exits 0 without prompting for a password.
2. Given the same user in a running `agent` container (as started by the normal compose service),
   when `sudo -n id -u` runs, then it prints `0`.
3. Given the same container, when the agent user runs `sudo -n apt-get update` followed by
   `sudo -n apt-get install -y <a small package not in the image, e.g. `tree`>`, then the install
   succeeds and the package's command is runnable afterwards. (Requires network access, as
   `bd`/harness already do.)
4. Given the image is built with either `HARNESS` value (claude-code or copilot), then criteria
   1-3 hold and the harness CLI, `bd`, `git`, `jq`, `curl` and `shellcheck` still work.
5. Given a file the agent writes into a host bind mount (e.g. its workspace), when it is written
   with or without sudo being available, then it is still owned by the invoking host user (the
   non-root user remains the default user; the container does not run as root by default).
6. Given the running `agent` container, then the existing confinement still holds: the docker
   socket and host `~/.ssh` are not present, the process/memory limits are still applied, and the
   host-config mounts are still read-only.
7. Given the agent instructions loaded by every role (the shared project conventions and the
   role-prompt text agents read), when an agent reads them, then they state that passwordless
   `sudo` is available and that installing packages needed for the assigned issue is allowed.
8. Given those same instructions, then they also say installs are for making the assigned work
   build/run/test (not for changing the container's security settings or touching things outside
   the agent's clone), and that anything a project needs permanently should be filed as an issue to
   add it to the image rather than relied on, since container changes do not persist across
   rebuilds.
9. Given `docs/ARCHITECTURE.md` and the README, when read, then they describe that the agent user
   has passwordless sudo and what hardening was adjusted to allow it.

## Out of scope
- Persisting runtime-installed packages across container restarts or image rebuilds.
- Granting sudo to any other service (e.g. `dolt`) or running the container as root by default.
- Pre-installing specific language toolchains (agent-factory-ncij).
- Restricting sudo to a command allowlist (full passwordless sudo is the requirement).
- Any change to network access, mounts, or credentials handling.
