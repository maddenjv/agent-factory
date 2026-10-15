# agent-factory-ncij: dev language toolchains in the agent image

## Story
As an agent-factory operator, I want the `agent` image to ship Python (with venv and pip), Perl,
a Java JDK, JavaScript (node + npm) and a C/C++ toolchain, so that agents working on projects in
those languages can build, run and test code without installing anything at runtime.

## Context
The `agent` image (`Dockerfile`, `node:bookworm-slim` base) currently carries only node (for the
harness CLI), git, jq, curl, shellcheck and `bd`. Agents on non-shell projects have no compilers or
interpreters, and the non-root agent user cannot install them. Package choices stay deliberately
minimal: the language tools themselves plus what is needed to compile, using ordinary Debian
packages. Split from agent-factory-0c7v.

## Acceptance criteria
1. Given a freshly built `agent` image, when `python3 --version` and `pip --version` run as the
   non-root agent user, then both succeed.
2. Given the same image and user, when `python3 -m venv <dir>` is run in a writable directory and
   the venv's `python` is then run, then the venv is created and its python runs and reports a
   version.
3. Given the same image and user, when `perl --version` runs, then it succeeds.
4. Given the same image and user, when `java -version` and `javac -version` run, then both succeed.
5. Given the same image and user, when `node --version` and `npm --version` run, then both succeed.
6. Given the same image and user, when `gcc --version`, `g++ --version` and `make --version` run,
   then all succeed.
7. Given the same image and user, when a trivial C program and a trivial C++ program (each
   including a standard library header) are compiled and run, then each builds and prints its
   expected output.
8. Given the image is built with either `HARNESS` value (claude-code or copilot), then all of the
   above hold and the harness CLI, `bd`, `git`, `jq`, `curl` and `shellcheck` still work.

## Out of scope
- Language libraries or dev packages beyond the interpreters/compilers and the standard
  headers/pip/venv support (no Python packages, Maven/Gradle, cmake, etc.).
- Pinning specific language versions; the Debian bookworm defaults are acceptable.
- Other languages (Go, Rust, Ruby, ...), and any change to the harness, user setup or runtime
  behaviour.
