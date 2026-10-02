# agent-factory-0tmj: Agent image builds when no `dotfiles/` exist

**Story**: As an operator who has not supplied any personal dotfiles, I want the `agent` image
to build successfully, so that `dotfiles/` is a truly optional customisation rather than a
hidden prerequisite for a first `bin/init.sh` run.

## Context

The `Dockerfile` copies the repo's `dotfiles/` directory into the container account's home so
operators can bake in shell/editor config. `dotfiles/*` is git-ignored (operator-supplied,
never committed), so a fresh clone has no `dotfiles/` directory at all, and the image build
fails at that copy step. The same optional-input pattern already exists for `extra-ca/`
(story `agent-factory-5njf`), which builds fine when empty.

## Acceptance criteria

1. Given a fresh clone with no `dotfiles/` directory, when the `agent` image is built (e.g. via
   `bin/init.sh`), then the build succeeds.
2. Given `dotfiles/` exists but is empty, when the image is built, then the build succeeds.
3. Given `dotfiles/` contains files (e.g. `.bashrc`, `.gitconfig`), when the image is built,
   then those files are present in the container user's home directory, owned by that user.
4. Given dotfiles are supplied, when they are present in the image, then files in `dotfiles/`
   are still never tracked by git (the operator's personal config is not committed).
5. Given the change, when the README/`docs/ARCHITECTURE.md` describe `dotfiles/`, then they
   state it is optional.

## Out of scope

- Changing which files are copied or where they land beyond making the input optional.
- Support for nested directories or symlink handling in `dotfiles/`.
- Any change to `extra-ca/` handling.
