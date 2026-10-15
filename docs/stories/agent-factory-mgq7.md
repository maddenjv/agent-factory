# agent-factory-mgq7: Agents can use the project's Python virtualenv inside the containers

## Story
As an operator who starts agent-factory in a project folder that has a `.venv`, I want every
agent's container to have a working Python virtualenv equivalent to it, so that agents can run the
project's Python code, tests and tools with the project's dependencies without me setting anything
up by hand.

## Context
- agent-factory is started from `PROJECT_DIR` (the project folder). Agents never work in
  `PROJECT_DIR` itself: each role works in its own git clone under
  `PROJECT_DIR/.agent-factory/workspaces/<role>`. A `.venv` is normally git-ignored, so it is
  absent from those clones.
- `PROJECT_DIR` is bind-mounted into the containers at the same path, but a host `.venv` is not
  usable there as-is: its `bin/python` is a symlink to a host interpreter and its scripts embed
  absolute host paths, neither of which resolve in the container.
- Decision: the behaviour is "an equivalent venv recreated inside the container", not "the host
  venv mounted and activated". The host `.venv` is only read, to learn which packages the project
  needs; it is never modified.
- Depends on `agent-factory-ncij` (Python toolchain and venv support in the agent image) landing
  first; this story assumes `python3` and `venv` are available in the image.

## Acceptance criteria
1. Given `PROJECT_DIR` contains a `.venv` and the agents are started, when an agent runs
   `python` (no path) in its workspace, then it resolves to a container-local virtualenv's
   interpreter that runs successfully, not the host's `.venv/bin/python`.
2. Given the host `.venv` has packages installed, when an agent imports each of them in that
   container venv, then the imports succeed at the versions installed in the host `.venv`.
3. Given the host `.venv` is present, when the agents run (including any package installation),
   then no file under the host `PROJECT_DIR/.venv` has been created, changed or deleted.
4. Given the container venv has already been built for the current host `.venv`, when the agents
   are restarted and the host `.venv` has not changed, then the venv is reused and packages are
   not reinstalled.
5. Given the host `.venv`'s installed packages change between runs (a package added, removed or
   changed version), when the agents are next started, then the container venv matches the new
   set.
6. Given `PROJECT_DIR` has no `.venv`, when the agents are started, then startup behaves exactly
   as before this story: no error, no warning, no venv created.
7. Given a package in the host `.venv` cannot be installed in the container (for example a wheel
   unavailable for the container's platform), when the agents are started, then startup still
   completes, the failure is reported in the startup output naming the package, and the
   remaining packages are still installed.
8. Given the container venv is in place, when an agent creates files in its workspace, then the
   venv's contents are not part of the clone's `git status` (nothing for the agent to commit).

## Out of scope
- Installing the Python toolchain or other languages in the image (`agent-factory-ncij`).
- Non-venv Python environments (conda, poetry-managed envs, pipenv) and non-Python environments
  such as `node_modules`.
- Modifying, repairing or rebuilding the host `.venv`.
- Making the container venv writable back to the host or shared between host and container.
- Per-role differences: all roles get the same venv.
