#!/usr/bin/env bash
# Tests for Podman, Incus and LXD support and engine selection, against
# fake CLIs (podman, incus/lxc, skopeo, systemctl) whose output follows what
# the real tools print (podman 4.9, incus 6.0). No container engine needed.
# Usage: tests/test_engines.sh   (or: make test)

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin" "$work/state" "$work/srv/demo" "$work/config/dports"
export FAKE_STATE="$work/state" FAKE_SRV="$work/srv"

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$(( fails + 1 )); }
expect() {  # expect DESCRIPTION OUTPUT REGEX
    if grep -Eq -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; printf '%s\n' "$2" | sed 's/^/        | /'; fi
}
reject() {
    if grep -Eq -- "$3" <<<"$2"; then fail "$1"; printf '%s\n' "$2" | sed 's/^/        | /'; else pass "$1"; fi
}

# ── fake podman ────────────────────────────────────────────────────────────
# Containers: web (plain), demo_app_1 (podman-compose, also has the
# PODMAN_SYSTEMD_UNIT label podman-compose sets), quadlet (systemd unit),
# stopped (created, port 7070). Names have no leading "/", image IDs have
# no "sha256:" prefix, and "dead" is not a valid status filter.
cat > "$bin/podman" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_STATE"
echo "podman $*" >> "$state/calls"
img_id() {
    case "$1" in
        docker.io/library/nginx:1.27) [[ -e "$state/pulled" ]] && echo nginxNEW || echo nginxOLD ;;
        docker.io/library/postgres:16) echo pgID ;;
        *) return 1 ;;
    esac
}
case "$1 $2" in
    "ps --format")
        printf '0.0.0.0:8080->80/tcp\tweb\tdocker.io/library/nginx:1.27\n'
        printf '0.0.0.0:9080->80/tcp\tdemo_app_1\tdocker.io/library/nginx:1.27\n'
        printf '\tquadlet\tdocker.io/library/postgres:16\n' ;;
    "ps -q") printf 'id-web\nid-demo_app_1\nid-quadlet\n' ;;
    "ps -aq")
        [[ "$*" == *status=dead* ]] && { echo "Error: unknown container state: dead: invalid argument" >&2; exit 125; }
        echo id-stopped ;;
    "info --format")
        [[ "$3" == *Host.OS* ]] || exit 125
        echo "linux/amd64" ;;
    "inspect --format")
        fmt="$3"; shift 3
        for id in "$@"; do
            case "$fmt" in
                *HostIP*)       [[ "$id" == id-stopped ]] && printf ':7070->80/tcp, \tstopped\tdocker.io/library/nginx:1.27\n' ;;
                *HostIp*)       exit 125 ;;   # podman has no HostIp field
                *config_files*)
                    case "$id" in
                        id-web)        printf 'web\tdocker.io/library/nginx:1.27\tnginxOLD\t\t\t\t\t\n' ;;
                        id-demo_app_1) printf 'demo_app_1\tdocker.io/library/nginx:1.27\tnginxOLD\tdemo\t%s\tcompose.yaml\tapp\tpodman-compose@demo.service\n' "$FAKE_SRV/demo" ;;
                        id-quadlet)    printf 'quadlet\tdocker.io/library/postgres:16\tpgOLD\t\t\t\t\tquadlet.service\n' ;;
                    esac ;;
                *)
                    case "$id" in
                        id-web) printf 'docker.io/library/nginx:1.27\tweb\n' ;;
                        id-demo_app_1) printf 'docker.io/library/nginx:1.27\tdemo_app_1\n' ;;
                        id-quadlet) printf 'docker.io/library/postgres:16\tquadlet\n' ;;
                    esac ;;
            esac
        done ;;
    "image inspect")
        shift 2; fmt="" ref=""
        while (( $# )); do case "$1" in --format) fmt="$2"; shift 2 ;; *) ref="$1"; shift ;; esac; done
        id=$(img_id "$ref") || exit 125
        if [[ "$fmt" == '{{.Id}}' ]]; then echo "$id"
        else
            case "$ref" in
                *nginx*) echo "$id docker.io/library/nginx@sha256:nginxIDX1 docker.io/library/nginx@sha256:nginxAMD1" ;;
                *postgres*) echo "$id docker.io/library/postgres@sha256:pgIDX docker.io/library/postgres@sha256:pgAMD" ;;
            esac
        fi ;;
    "manifest inspect")
        case "$3" in
            *postgres*) printf '{"schemaVersion":2,"manifests":[{"digest":"sha256:pgARM","platform":{"architecture":"arm64","os":"linux"}},{"digest":"sha256:pgAMD","platform":{"architecture":"amd64","os":"linux"}}]}\n' ;;
            *) echo "Error: denied" >&2; exit 125 ;;
        esac ;;
    "pull "*) : > "$state/pulled"; echo "ok" ;;
    "compose "*) echo "$PWD|$*" >> "$state/compose"; echo "recreated" ;;
    *) echo "fake podman: unsupported: $*" >&2; exit 125 ;;
esac
EOF

# ── fake skopeo: knows nginx (newer in the registry), fails for the rest ──
cat > "$bin/skopeo" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *nginx*) echo "sha256:nginxIDX2" ;;
    *) echo "FATA[0000] Error parsing image name: unauthorized" >&2; exit 1 ;;
esac
EOF

cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_STATE/systemctl"
EOF

# ── fake incus (and lxc): the REST API through `incus query` ──────────────
# web1 running, proxies 8180->80 and 9100-9101; stopped1 with 5433->5432;
# a forward 192.0.2.2:2222 -> 10.24.63.10:22 on the managed bridge.
cat > "$bin/incus" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$FAKE_STATE/calls"
[[ "$1" == query ]] || { echo "fake incus: unsupported: $*" >&2; exit 1; }
inst() {  # inst WITH_STATE
    local st='null'
    [[ "$1" == 1 ]] && st='{"status":"Running","network":{"eth0":{"addresses":[{"address":"10.24.63.10","family":"inet","netmask":"24","scope":"global"}]},"lo":{"addresses":[{"address":"127.0.0.1","family":"inet","netmask":"8","scope":"local"}]}}}'
    printf '[{"name":"stopped1","project":"default","status":"Stopped","type":"container","config":{"image.description":"Alpine 3.20"},"expanded_devices":{"db":{"type":"proxy","listen":"tcp:0.0.0.0:5433","connect":"tcp:127.0.0.1:5432"},"root":{"type":"disk","path":"/"}},"state":null},'
    printf '{"name":"web1","project":"default","status":"Running","type":"container","config":{"image.os":"Alpine","image.release":"3.20"},"expanded_devices":{"http":{"type":"proxy","listen":"tcp:0.0.0.0:8180","connect":"tcp:127.0.0.1:80"},"multi":{"type":"proxy","listen":"tcp:0.0.0.0:9100-9101","connect":"tcp:127.0.0.1:9100-9101"}},"state":%s}]\n' "$st"
}
case "$2" in
    "/1.0/networks?recursion=1") echo '[{"name":"incusbr0","managed":true,"type":"bridge"},{"name":"eth0","managed":false,"type":"physical"}]' ;;
    "/1.0/networks/incusbr0/forwards?recursion=1")
        [[ -n "${FAKE_NO_FORWARDS:-}" ]] && { echo '[]'; exit 0; }
        echo '[{"config":{},"listen_address":"192.0.2.2","ports":[{"listen_port":"2222","protocol":"tcp","target_address":"10.24.63.10","target_port":"22"}]}]' ;;
    "/1.0/instances?recursion=1&all-projects=true") inst 0 ;;
    "/1.0/instances?recursion=2&all-projects=true") inst 1 ;;
    *) echo "Error: not found" >&2; exit 1 ;;
esac
EOF
ln -s incus "$bin/lxc"
chmod +x "$bin"/*
export PATH="$bin:$PATH"
export XDG_CONFIG_HOME="$work/config"
unset DPORTS_ENGINES

run() { bash "$root/dports.bash" "$@" 2>&1 </dev/null; }
fresh() { rm -f "$work/state"/*; }

echo "engines: listing"
fresh
out=$(run --engine podman,incus -C)
expect "an ENGINE column with several engines"     "$out" '^PORT +NAME +ENGINE +IMAGE$'
expect "podman containers are listed"              "$out" '^8080 +web +podman +docker.io/library/nginx:1.27$'
expect "incus proxy devices are listed"            "$out" '^8180 +web1 +incus +Alpine 3.20$'
expect "port ranges of proxy devices"              "$out" '^9100-9101 +web1 +incus'
expect "network forwards map to the instance"      "$out" '^2222 +web1 +incus'
reject "stopped instances need -a"                 "$out" '5433'
expect "forwards need the instances' addresses (state)" "$(cat "$work/state/calls")" 'recursion=2'
fresh
FAKE_NO_FORWARDS=1 run --engine incus -C >/dev/null
reject "without forwards, the cheaper listing is enough" "$(cat "$work/state/calls")" 'recursion=2'
out=$(run --engine podman,incus -C -v -a)
expect "-a lists stopped podman containers (HostIP)" "$out" '^7070 +stopped +80/tcp +podman'
expect "-a lists stopped incus instances"          "$out" '^5433 +stopped1 +5432/tcp +incus'
expect "forwards show the target port"             "$out" '^2222 +web1 +22/tcp +incus'
out=$(run --engine incus -j)
expect "JSON has the engine field"                 "$out" '"port": "8180", "name": "web1", "internal": "80/tcp", "image": "Alpine 3.20", "engine": "incus"'
out=$(run --engine podman -C)
expect "one engine: no ENGINE column"              "$out" '^PORT +NAME +IMAGE$'
fresh
out=$(run --engine lxd -C)
expect "lxd uses the lxc command"                  "$(cat "$work/state/calls")" '^lxc query'
expect "lxd lists the same way"                    "$out" '^8180 +web1 +Alpine 3.20$'
out=$(run --engine podman -C -n quadlet)
expect "containers without ports are not listed"   "$out" 'No containers match'

echo "engines: selection"
out=$(run --engine nonsense)
expect "unknown engines are rejected"              "$out" "unknown engine 'nonsense'"
printf '# test\nengines = incus\n' > "$XDG_CONFIG_HOME/dports/config"
out=$(run engines)
expect "the config file chooses the engines"       "$out" '^incus +yes +[a-z]+ +yes +incus$'
expect "dports engines names the source"           "$out" "set in $XDG_CONFIG_HOME/dports/config"
out=$(DPORTS_ENGINES=podman run engines)
expect "DPORTS_ENGINES overrides the config"       "$out" '^podman +yes +[a-z]+ +yes +podman$'
out=$(DPORTS_ENGINES=podman run --engine incus -C)
expect "--engine overrides DPORTS_ENGINES"         "$out" '^8180 +web1'
rm -f "$XDG_CONFIG_HOME/dports/config"

echo "engines: dports update with podman"
fresh
out=$(run --engine podman,incus update --check -C)
expect "skopeo finds the newer nginx"              "$out" '^docker.io/library/nginx:1.27 +update +web, demo_app_1$'
expect "manifest fallback: postgres is current"    "$out" '^docker.io/library/postgres:16 +current +quadlet$'
expect "systemd (Quadlet) containers restart their unit" "$out" 'systemctl (--user )?restart quadlet.service$'
reject "containers on their tag's image are not outdated" "$out" '^  (cd .*demo|web [(])'
fresh
out=$(run --engine podman update --yes -C)
expect "after a pull, compose services recreate with --force-recreate" "$out" "cd $work/srv/demo && podman compose up -d --force-recreate app\$"
reject "Compose labels win over podman-compose's unit label" "$out" 'podman-compose@demo'
expect "other containers are recreated by hand"    "$out" '^  web [(]not managed by Compose or systemd'
[[ ! -e "$work/state/compose" ]] && pass "--yes alone recreates nothing" || fail "--yes alone recreates nothing"
fresh
out=$(run --engine podman update --yes --recreate -C)
expect "the update is pulled"                      "$out" 'docker.io/library/nginx:1.27 +updated$'
expect "compose runs in the project directory"     "$(cat "$work/state/compose" 2>/dev/null)" "^$work/srv/demo\\|compose -p demo -f compose.yaml up -d --no-deps --force-recreate app\$"
expect "the unit is restarted"                     "$(cat "$work/state/systemctl" 2>/dev/null)" 'restart quadlet.service$'
expect "both are reported"                         "$out" '^  quadlet.service +recreated$'
out=$(run --engine incus update)
expect "update explains Incus/LXD"                 "$out" 'works with Docker and Podman'

echo
if (( fails )); then echo "$fails test(s) failed"; exit 1; fi
echo "All tests passed"
