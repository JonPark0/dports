#!/usr/bin/env bash
# Tests for `dports update` against tests/fake-docker (no Docker needed).
# Usage: tests/test_update.sh   (or: make test)

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
ln -s "$here/fake-docker" "$work/bin/docker"
export PATH="$work/bin:$PATH"

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$(( fails + 1 )); }
expect() {  # expect DESCRIPTION OUTPUT REGEX
    if grep -Eq -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; printf '%s\n' "$2" | sed 's/^/        | /'; fi
}
reject() {  # reject DESCRIPTION OUTPUT REGEX
    if grep -Eq -- "$3" <<<"$2"; then fail "$1"; printf '%s\n' "$2" | sed 's/^/        | /'; else pass "$1"; fi
}
fresh() { rm -rf "$work/state"; mkdir -p "$work/state"; export FAKE_STATE="$work/state"; }

run_bash() { bash "$root/dports.bash" "$@" 2>&1 </dev/null; }

echo "dports update (bash)"

fresh
out=$(run_bash -C update --check)
expect "update available is detected"        "$out" '^nginx:latest +update +web, proxy$'
expect "matching digest is current"          "$out" '^postgres:16 +current +db$'
expect "image without registry digest is local" "$out" '^myapp:dev +local +app$'
expect "digest reference is pinned"          "$out" '^redis@sha256:1+ +pinned +cache$'
expect "unreachable registry is unknown"     "$out" '^registry.example.com/team/api:1 +unknown +priv$'
expect "summary counts updates"              "$out" '^8 image\(s\) checked, 1 with updates\.$'
[[ ! -e "$work/state/pulls" ]] && pass "--check pulls nothing" || fail "--check pulls nothing"
expect "bare name missing on Docker Hub is local (containerd store)" "$out" '^mysite +local +site$'
expect "rate limit is unknown"               "$out" '^someone/tool:2 +unknown +hub$'

fresh
out=$(run_bash update -C)
expect "no terminal falls back to the report" "$out" 'Not a terminal: nothing was pulled'
[[ ! -e "$work/state/pulls" ]] && pass "no terminal pulls nothing" || fail "no terminal pulls nothing"

fresh
out=$(run_bash -C update --yes)
pulls=$(cat "$work/state/pulls" 2>/dev/null)
[[ "$pulls" == "nginx:latest" ]] && pass "--yes pulls only images with updates" \
    || { fail "--yes pulls only images with updates"; echo "        | pulled: $pulls"; }
expect "pull result is reported"             "$out" 'nginx:latest +updated$'
expect "compose project gets a recreate hint" "$out" '^  cd /srv/site && docker compose up -d web proxy$'
reject "unchanged images get no hint"        "$out" 'my\\ app'

fresh
out=$(FAKE_BUILDX=0 FAKE_ARCH=armv7l run_bash -C update --check)
expect "arm/v7 host matches the v7 manifest, not v5" "$out" '^multi:latest +current +multi$'
out=$(FAKE_BUILDX=0 FAKE_ARCH=x86_64 run_bash -C update --check)
expect "amd64 host compares the amd64 manifest" "$out" '^multi:latest +update +multi$'

# The reason shown under the checklist (no terminal needed: call the check directly)
reason() { bash -c "source '$root/dports.bash'; dports --help >/dev/null; _dports_check_image_update '$1' linux/amd64"; }
expect "local reason names Docker Hub"       "$(reason mysite)" $'^local\tNot on Docker Hub: built locally$'
expect "rate limit reason"                   "$(reason someone/tool:2)" 'rate limit reached'
expect "private registry reason names host"  "$(reason registry.example.com/team/api:1)" '^unknown.Access denied: private image. [(]docker login registry[.]example[.]com[)]$'

out=$(run_bash update --bogus)
expect "unknown update option is rejected"   "$out" 'Unknown update option: --bogus'
out=$(run_bash update --help)
expect "update has its own help"             "$out" 'Pull every image that has an update'

if command -v fish >/dev/null 2>&1; then
    echo "dports update (fish delegates to dports.bash)"
    fresh
    out=$(fish --no-config -c "source '$root/dports.fish'; dports -C update --check" 2>&1 </dev/null)
    expect "fish runs the bash implementation"  "$out" '^nginx:latest +update +web, proxy$'
    out=$(fish --no-config -c "source '$root/dports.fish'; dports update --bogus" 2>&1 </dev/null)
    expect "fish passes update options through" "$out" 'Unknown update option: --bogus'
fi

echo
if (( fails )); then echo "$fails test(s) failed"; exit 1; fi
echo "All tests passed"
