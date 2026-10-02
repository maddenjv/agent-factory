#!/usr/bin/env bash
# Acceptance tests for agent-factory-5njf (additional CA certificates in the agent image).
# One test function per acceptance criterion in docs/stories/agent-factory-5njf.md:
#   bash tests/acceptance/agent-factory-5njf.sh
# Written before implementation, from the story only. The story leaves the directory name open
# ("a dedicated directory in the repo checkout"); these tests use $EXTRA_CA_DIR (default
# "extra-ca") relative to the repo root - export EXTRA_CA_DIR to match the implementation.
# Image tests need docker + network (the Dockerfile pulls npm/go packages) and build from a scratch
# copy of the repo under a throwaway tag, so factory-agent:latest is never touched. Without docker
# they are SKIPped (reported, not failed); the git-ignore/doc check (AC6) always runs.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KIT_DIR"
CA_DIR="${EXTRA_CA_DIR:-extra-ca}"

pass=0; fail=0; skip=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
skp()  { echo "SKIP: $1"; skip=$((skip+1)); }

cleanup_dirs=(); cleanup_imgs=(); cleanup_ctrs=()
cleanup() {
  for c in "${cleanup_ctrs[@]}"; do docker rm -f "$c" >/dev/null 2>&1; done
  for i in "${cleanup_imgs[@]}"; do docker rmi -f "$i" >/dev/null 2>&1; done
  for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done
}
trap cleanup EXIT
mktmp() { local d; d=$(mktemp -d); cleanup_dirs+=("$d"); echo "$d"; }

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  HAVE_DOCKER=1
fi
RUN_ID="t$$"

# --- fixtures -------------------------------------------------------------------------------
W=$(mktmp)
gen_ca() {  # <name>: self-signed CA in $W
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/$1.key" -out "$W/$1.crt" -days 2 \
    -subj "/CN=af-test-$1-$RUN_ID" >/dev/null 2>&1
}
gen_server() {  # <ca-name> <server-name>: localhost server cert signed by that CA
  openssl req -newkey rsa:2048 -nodes -keyout "$W/$2.key" -out "$W/$2.csr" -subj "/CN=localhost" >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$W/$2.ext"
  openssl x509 -req -in "$W/$2.csr" -CA "$W/$1.crt" -CAkey "$W/$1.key" -CAcreateserial \
    -out "$W/$2.crt" -days 2 -extfile "$W/$2.ext" >/dev/null 2>&1
}
pem_body() { grep -v -- '-----' "$1" | tr -d '\n'; }

# make_ctx <ca-file>...: scratch build context = tracked tree + extra-CA dir holding the files
make_ctx() {
  local d; d=$(mktmp)
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"
  mkdir -p "$d/$CA_DIR"
  local f; for f in "$@"; do cp "$f" "$d/$CA_DIR/"; done
  echo "$d"
}
build_img() {  # <ctx> <suffix>; log in $W/build-<suffix>.log
  cleanup_imgs+=("af-5njf-$2-$RUN_ID")
  docker build -t "af-5njf-$2-$RUN_ID" "$1" >"$W/build-$2.log" 2>&1
}
img() { echo "af-5njf-$1-$RUN_ID"; }
in_img() { local s=$1; shift; docker run --rm --entrypoint bash "$(img "$s")" -c "$*"; }

if [ "$HAVE_DOCKER" = 1 ]; then
  gen_ca ca1; gen_server ca1 srv1       # CA that gets supplied
  gen_ca ca2; gen_server ca2 srv2       # CA never supplied (negative control)
  CTX_A=$(make_ctx);              build_img "$CTX_A" A; A_RC=$?
  CTX_B=$(make_ctx "$W/ca1.crt"); build_img "$CTX_B" B; B_RC=$?
  rm -f "${CTX_B:?}/${CA_DIR:?}/ca1.crt";  build_img "$CTX_B" E; E_RC=$?   # supplied, then removed
  CTX_M=$(make_ctx "$W/ca1.crt" "$W/ca2.crt"); build_img "$CTX_M" M; M_RC=$?
fi

start_server() {  # <srv-name> <port>; sets $SRV (container running as the image's agent user)
  SRV="af-5njf-srv-$1-$RUN_ID"; cleanup_ctrs+=("$SRV")
  docker run -d --name "$SRV" -v "$W:/fx:ro" --entrypoint node "$(img B)" -e '
    const https=require("https"),fs=require("fs");
    https.createServer({key:fs.readFileSync("/fx/'"$1"'.key"),cert:fs.readFileSync("/fx/'"$1"'.crt")},
      (q,r)=>{r.writeHead(200,{"content-type":"text/plain"});r.end("ok\n")}).listen('"$2"',"127.0.0.1");
    setInterval(()=>{},1000)' >/dev/null
  sleep 2
}

test_ac1_no_extra_cas_builds_and_trust_store_unchanged() {
  local n="AC1 no extra CAs: build succeeds, trust store identical to base"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker/openssl)"; return; }
  if [ "$A_RC" != 0 ]; then bad "$n - build failed: $(tail -5 "$W/build-A.log")"; return; fi
  local base_ctx; base_ctx=$(mktmp)
  printf 'FROM node:bookworm-slim\nRUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*\n' > "$base_ctx/Dockerfile"
  build_img "$base_ctx" BASE || { bad "$n - could not build reference base image"; return; }
  local a b
  a=$(in_img A 'sha256sum < /etc/ssl/certs/ca-certificates.crt')
  b=$(in_img BASE 'sha256sum < /etc/ssl/certs/ca-certificates.crt')
  [ -n "$a" ] && [ "$a" = "$b" ] && ok "$n" || bad "$n - bundle differs (agent=$a base=$b)"
}

test_ac2_supplied_certs_in_system_trust_store() {
  local n="AC2 supplied *.crt present in /etc/ssl/certs/ca-certificates.crt"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker/openssl)"; return; }
  if [ "$B_RC" != 0 ] || [ "$M_RC" != 0 ]; then bad "$n - build failed: $(tail -5 "$W/build-B.log" "$W/build-M.log")"; return; fi
  local b1 b2 bundle
  b1=$(pem_body "$W/ca1.crt"); b2=$(pem_body "$W/ca2.crt")
  bundle=$(in_img B 'tr -d "\n" < /etc/ssl/certs/ca-certificates.crt')
  grep -qF "$b1" <<<"$bundle" || { bad "$n - ca1 missing from bundle (one-cert image)"; return; }
  bundle=$(in_img M 'tr -d "\n" < /etc/ssl/certs/ca-certificates.crt')
  grep -qF "$b1" <<<"$bundle" && grep -qF "$b2" <<<"$bundle" && ok "$n" || bad "$n - two-cert image misses a cert"
}

test_ac3_curl_and_git_trust_extra_ca_as_agent_user() {
  local n="AC3 curl and git (HTTPS) succeed against server signed by extra CA, as agent user"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker/openssl)"; return; }
  [ "$B_RC" = 0 ] || { bad "$n - image B failed to build"; return; }
  start_server srv1 8443
  local who out; who=$(docker exec "$SRV" id -un)
  [ "$who" != root ] || { bad "$n - ran as root, not the agent user"; return; }
  out=$(docker exec "$SRV" curl -sS https://localhost:8443/ 2>&1)
  [ "$out" = ok ] || { bad "$n - curl: $out"; return; }
  # Not a git server, so git fails on protocol - but must never fail on certificates.
  out=$(docker exec -e GIT_TERMINAL_PROMPT=0 "$SRV" git ls-remote https://localhost:8443/x.git 2>&1)
  if grep -qiE 'ssl|certificate|verify' <<<"$out"; then bad "$n - git certificate error: $out"; return; fi
  # Negative control: a server from a never-supplied CA must still be rejected.
  start_server srv2 8444
  out=$(docker exec "$SRV" curl -sS https://localhost:8444/ 2>&1)
  if [ "$out" = ok ]; then bad "$n - untrusted CA accepted by curl (verification disabled?)"; return; fi
  out=$(docker exec -e GIT_TERMINAL_PROMPT=0 "$SRV" git ls-remote https://localhost:8444/x.git 2>&1)
  grep -qiE 'ssl|certificate|verify' <<<"$out" && ok "$n" || bad "$n - git accepted untrusted CA: $out"
}

test_ac4_node_trusts_extra_ca() {
  local n="AC4 node (claude) trusts extra CA (NODE_EXTRA_CA_CERTS or equivalent)"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker/openssl)"; return; }
  [ "$B_RC" = 0 ] || { bad "$n - image B failed to build"; return; }
  start_server srv1 8445
  local out v
  out=$(docker exec "$SRV" node -e '
    require("https").get("https://localhost:8445/",r=>{let b="";r.on("data",d=>b+=d);r.on("end",()=>{console.log(b.trim());process.exit(0)})})
      .on("error",e=>{console.log("ERR "+e.message);process.exit(1)})' 2>&1)
  [ "$out" = ok ] || { bad "$n - node https: $out"; return; }
  v=$(in_img B 'echo "${NODE_EXTRA_CA_CERTS:-}"')
  if [ -n "$v" ] && ! in_img B "test -s '$v'"; then bad "$n - NODE_EXTRA_CA_CERTS=$v missing in image"; return; fi
  ok "$n"
}

test_ac5_invalid_pem_fails_build_naming_file() {
  local n="AC5 invalid cert file fails the build and names the offending file"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker/openssl)"; return; }
  local ctx; ctx=$(make_ctx "$W/ca1.crt")
  echo "this is not a certificate" > "$ctx/$CA_DIR/not-a-cert-$RUN_ID.crt"
  if build_img "$ctx" BAD; then bad "$n - build succeeded"; return; fi
  grep -q "not-a-cert-$RUN_ID.crt" "$W/build-BAD.log" && ok "$n" || bad "$n - log does not name the file: $(tail -5 "$W/build-BAD.log")"
}

test_ac6_dir_gitignored_and_documented() {
  local n="AC6 certs in extra-CA dir are git-ignored; dir and rebuild step documented in ARCHITECTURE.md"
  local d st ignored=1 docs=1; d=$(mktmp)
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"
  git -C "$d" init -q -b main; git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
  mkdir -p "$d/$CA_DIR"
  printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' > "$d/$CA_DIR/corp.crt"
  st=$(git -C "$d" status --porcelain)
  grep -q "$CA_DIR" <<<"$st" && ignored=0
  grep -qF "$CA_DIR" docs/ARCHITECTURE.md || docs=0
  grep -qiE 'rebuild|docker compose build' docs/ARCHITECTURE.md || docs=0
  if [ $ignored = 1 ] && [ $docs = 1 ]; then ok "$n"
  else bad "$n - git-ignored=$ignored documented=$docs (status: ${st:-<clean>})"; fi
}

test_ac7_removed_cert_no_longer_trusted() {
  local n="AC7 removing the CA and rebuilding drops it from the trust store"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker/openssl)"; return; }
  if [ "$E_RC" != 0 ]; then bad "$n - rebuild failed: $(tail -5 "$W/build-E.log")"; return; fi
  local body v; body=$(pem_body "$W/ca1.crt")
  if in_img E 'tr -d "\n" < /etc/ssl/certs/ca-certificates.crt' | grep -qF "$body"; then
    bad "$n - ca1 still in bundle after removal + rebuild"; return
  fi
  v=$(in_img E 'echo "${NODE_EXTRA_CA_CERTS:-}"')
  if [ -n "$v" ] && in_img E "tr -d '\n' < '$v'" 2>/dev/null | grep -qF "$body"; then
    bad "$n - ca1 still reachable via NODE_EXTRA_CA_CERTS=$v"; return
  fi
  ok "$n"
}

test_ac1_no_extra_cas_builds_and_trust_store_unchanged
test_ac2_supplied_certs_in_system_trust_store
test_ac3_curl_and_git_trust_extra_ca_as_agent_user
test_ac4_node_trusts_extra_ca
test_ac5_invalid_pem_fails_build_naming_file
test_ac6_dir_gitignored_and_documented
test_ac7_removed_cert_no_longer_trusted

echo "passed=$pass failed=$fail skipped=$skip"
[ "$fail" -eq 0 ]
