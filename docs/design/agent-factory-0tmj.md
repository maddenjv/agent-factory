# Design: `dotfiles/` is optional (agent-factory-0tmj)

Story: `docs/stories/agent-factory-0tmj.md`. Same pattern as `extra-ca/` (design `agent-factory-5njf`).

## Problem
`Dockerfile` ends with `COPY --chown=... dotfiles/* /home/${HOST_USER}`. `dotfiles/*` is git-ignored,
so a fresh clone has no `dotfiles/` and the build fails; an empty `dotfiles/` makes the glob match
nothing, which also fails. (A multi-source glob onto a destination without a trailing `/` is also
fragile.)

## Approach
Make the directory always exist in a checkout and copy it as a directory.

1. **`dotfiles/.gitkeep`** (new, tracked, empty). Guarantees `COPY dotfiles/` has a source (AC1, AC2).
2. **`.gitignore`**: replace `dotfiles/*` with
   ```
   dotfiles/*
   !dotfiles/.gitkeep
   ```
   (keep the existing comment line). `dotfiles/` itself must not be ignored or the `!` has no
   effect. Operator files stay untracked (AC4).
3. **`Dockerfile`**: replace the `COPY ... dotfiles/*` line with
   ```dockerfile
   COPY --chown=${HOST_UID}:${HOST_GID} dotfiles/ /home/${HOST_USER}/
   RUN rm -f /home/${HOST_USER}/.gitkeep
   ```
   Still under `USER ${HOST_USER}` so the `rm` runs as the owner of the file. Copying the
   directory (trailing slashes) copies its contents including dotfiles such as `.bashrc` /
   `.gitconfig` into the home dir, owned by `HOST_UID:HOST_GID` (AC3). The `rm` stops the
   placeholder landing in the home dir. Empty directory: `COPY` of an empty dir succeeds and
   copies nothing. Which files are copied/where they land is unchanged (out of scope: nested
   dirs, symlinks).
   Note: the `rm` also removes an operator's own `.gitkeep` from home - harmless.
4. **Docs (AC5)**: in `docs/ARCHITECTURE.md` add a bullet next to "Extra CA certificates" in the
   build-time customisation list: `dotfiles/` is optional; files in it (e.g. `.bashrc`,
   `.gitconfig`) are copied into the container user's home at image build (git-ignored, never
   commit them); rebuild with `docker compose build agent`; `dotfiles/.gitkeep` must stay
   (restore: `mkdir dotfiles && touch dotfiles/.gitkeep`). Add a `dotfiles/` line to the Layout
   block. In `README.md`, add a one-line "optional" mention where image customisation / `extra-ca/`
   is described, or - if README says nothing about either - skip README (it currently has no
   `dotfiles` mention).

## Test strategy (QA)
- Static (cheap, always run): `Dockerfile` has no `dotfiles/*` glob; `dotfiles/.gitkeep` is tracked
  (`git ls-files`); `git check-ignore dotfiles/.bashrc` succeeds and `git check-ignore
  dotfiles/.gitkeep` fails; ARCHITECTURE.md mentions `dotfiles/` and "optional".
- Build-level (follow the existing extra-ca acceptance tests' skip-if-no-docker convention): build
  from a copy of the repo with (a) `dotfiles/` removed entirely only if you treat AC1 as "no
  tracked placeholder" - note a fresh *clone* always has `.gitkeep`, so test (a) by cloning/`git
  archive` instead of deleting; (b) empty `dotfiles/` (just `.gitkeep`); (c) `dotfiles/.bashrc` +
  `.gitconfig`: run the image and check both exist in `$HOME`, are owned by the uid, and that
  `.gitkeep` is absent.
- Robustness case worth one test: the directory deleted outright makes `COPY` fail - this is
  accepted and documented (same as extra-ca), not required to pass.

## Single engineer task
No split needed; one implement issue (Dockerfile, .gitignore, `.gitkeep`, docs).
