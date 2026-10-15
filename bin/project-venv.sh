#!/usr/bin/env bash
# Recreate the host PROJECT_DIR/.venv as a container-local venv at $VENV_DIR (default
# $DATA_DIR/venv). The host .venv is only read (its dist-info names), never executed or modified.
# Always exits 0: a venv problem must never stop an agent from starting. See
# docs/design/agent-factory-mgq7.md.
#
# Env: PROJECT_DIR (required), DATA_DIR, VENV_DIR, PYTHON (default python3). pip's own PIP_* env
# (index, find-links, ...) passes through.
set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:?PROJECT_DIR must be set}"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/.agent-factory}"
VENV_DIR="${VENV_DIR:-$DATA_DIR/venv}"
PYTHON="${PYTHON:-python3}"
log() { echo "venv: $*"; }

[ -d "$PROJECT_DIR/.venv" ] || exit 0

sp=$(ls -d "$PROJECT_DIR"/.venv/lib/python*/site-packages 2>/dev/null | sort | head -1)
[ -n "$sp" ] || { log "host .venv has no site-packages; skipping"; exit 0; }

# name==version of every installed distribution; direct-URL (editable/path/VCS) installs can't be
# reproduced from a version, so they are reported as failures instead.
pkgs=(); failures=()
for d in "$sp"/*.dist-info; do
  [ -d "$d" ] || continue
  n=$(basename "$d" .dist-info)
  name=${n%-*}; name=${name//_/-}; ver=${n##*-}
  if [ -f "$d/direct_url.json" ]; then
    failures+=("$name (direct-URL/editable install; not reproducible)")
  else
    pkgs+=("$name==$ver")
  fi
done
if [ "${#pkgs[@]}" -gt 0 ]; then
  mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort)
fi

if ! command -v "$PYTHON" >/dev/null 2>&1 || ! "$PYTHON" -c 'import venv, ensurepip' >/dev/null 2>&1; then
  log "python3/venv not available in this image (agent-factory-ncij); skipping"
  exit 0
fi

stamp=$({ "$PYTHON" -V 2>&1; printf '%s\n' ${pkgs[@]+"${pkgs[@]}"}; printf 'direct:%s\n' ${failures[@]+"${failures[@]}"}; } | sha256sum | cut -d' ' -f1)
if [ "$(cat "$VENV_DIR/.af-stamp" 2>/dev/null)" = "$stamp" ] && "$VENV_DIR/bin/python" -c 'pass' >/dev/null 2>&1; then
  log "up to date (${#pkgs[@]} packages)"
  exit 0
fi

rm -rf "$VENV_DIR"
if ! err=$("$PYTHON" -m venv "$VENV_DIR" 2>&1); then
  log "cannot create $VENV_DIR: $err"
  rm -rf "$VENV_DIR"
  exit 0
fi

export PIP_CERT="${PIP_CERT:-/etc/ssl/certs/ca-certificates.crt}" PIP_DISABLE_PIP_VERSION_CHECK=1
pip=("$VENV_DIR/bin/python" -m pip install --no-deps -q)
installed=${#pkgs[@]}
if [ "${#pkgs[@]}" -gt 0 ] && ! "${pip[@]}" "${pkgs[@]}" >/dev/null 2>&1; then
  installed=0
  for p in "${pkgs[@]}"; do
    if out=$("${pip[@]}" "$p" 2>&1); then
      installed=$((installed + 1))
    else
      failures+=("$p: $(printf '%s\n' "$out" | grep -v '^\s*$' | tail -1)")
    fi
  done
fi

for f in ${failures[@]+"${failures[@]}"}; do log "FAILED to install $f"; done
log "$installed installed, ${#failures[@]} failed"

touch "$VENV_DIR/.af-ready"
[ "${#failures[@]}" -eq 0 ] && printf '%s\n' "$stamp" > "$VENV_DIR/.af-stamp"
exit 0
