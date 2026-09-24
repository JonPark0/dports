#!/usr/bin/env bash
#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.3.0
# License: MIT
#
# Installation:
#   Bash: Copy to ~/.bash_functions/dports and source from ~/.bashrc
#   Or:   Source this file directly in ~/.bashrc
#   Apt:  sudo apt install dports  (via Forgejo package registry)
#

DPORTS_VERSION="2.3.0"

dports() {
    # Colors (disabled if not a terminal)
    local C_RESET C_BOLD C_DIM C_CYAN C_GREEN C_YELLOW
    if [[ -t 1 ]]; then
        C_RESET='\033[0m'
        C_BOLD='\033[1m'
        C_DIM='\033[2m'
        C_CYAN='\033[36m'
        C_GREEN='\033[32m'
        C_YELLOW='\033[33m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN='' C_YELLOW=''
    fi

    local verbose=false
    local show_all=false
    local filter_port=""
    local filter_name=""
    local filter_image=""
    local quiet=false
    local json_output=false
    local show_tunnel=false

    # Help function (local to dports)
    _dports_usage() {
        cat <<'EOF'
dports - Display Docker container port mappings

USAGE:
    dports [OPTIONS]
    dports update

SUBCOMMANDS:
    update              Check running container images for updates (interactive TUI)

OPTIONS:
    -v, --verbose       Show detailed port mapping (external -> internal)
    -a, --all           Include stopped containers
    -p, --port PORT     Filter by port number (exact match)
    -n, --name NAME     Filter by container name (partial match, case-insensitive)
    -i, --image IMAGE   Filter by image name (partial match, case-insensitive)
    -c, --color         Force color output (even when piped)
    -C, --no-color      Disable color output
    -t, --tunnel        Also show Cloudflare Tunnel routes (cloudflared containers)
    -q, --quiet         Only show port numbers (one per line)
    -j, --json          Output in JSON format
    -h, --help          Show this help message
    -V, --version       Show version information

EXAMPLES:
    dports                      List all running containers with exposed ports
    dports update               Check for and pull image updates interactively
    dports -v                   Show with internal port mapping details
    dports -a                   Include stopped containers
    dports -p 8080              Show only containers using port 8080
    dports -n nginx             Filter by container name containing "nginx"
    dports -i postgres          Filter by image name containing "postgres"
    dports -n web -p 80         Combine filters (AND logic)
    dports -q                   List only port numbers
    dports -j                   Output as JSON array
    dports -t                   Also list hostnames served through Cloudflare Tunnel
    dports -t -j                Tunnel routes only, as JSON
    dports -q | xargs -I{}      Pipe ports to another command

OUTPUT COLUMNS:
    PORT        Host port (external)
    NAME        Container name
    INTERNAL    Internal port with protocol (verbose mode only)
    IMAGE       Docker image name

EOF
    }

    # ── update helpers ─────────────────────────────────────────────────────────

    _dports_update_get_dialog_tool() {
        if command -v whiptail &>/dev/null; then echo "whiptail"
        elif command -v dialog &>/dev/null; then echo "dialog"
        fi
    }

    # Check whether a single image has an available update.
    # Compares the digests recorded when the image was pulled (RepoDigests)
    # against the registry, which works with both the classic and the
    # containerd image store.
    # Usage: _dports_check_image_update IMAGE [OS/ARCH]
    # Prints: update-available | up-to-date | pinned | ?
    _dports_check_image_update() {
        local image="$1" platform="${2:-linux/amd64}"
        local os="${platform%%/*}" arch="${platform#*/}"

        # Digest-pinned references can never change by pulling
        [[ "$image" == *@sha256:* ]] && { echo "pinned"; return; }

        local inspect local_id repo_digests=" " ref
        inspect=$(docker image inspect "$image" \
            --format '{{.Id}}{{range .RepoDigests}} {{.}}{{end}}' 2>/dev/null) || { echo "?"; return; }
        local_id="${inspect%% *}"
        for ref in ${inspect#"$local_id"}; do
            repo_digests+="${ref##*@} "
        done
        # Locally built images have no registry digest to compare against
        [[ -z "$local_id" || "$repo_digests" == " " ]] && { echo "?"; return; }

        # Preferred: buildx reports the top-level (index) digest directly.
        # Parse its default output: older buildx releases ignore --format.
        local remote_digest=""
        if docker buildx version &>/dev/null; then
            remote_digest=$(docker buildx imagetools inspect "$image" 2>/dev/null \
                | awk '$1 == "Digest:" { print $2; exit }')
        fi
        if [[ "$remote_digest" == sha256:* ]]; then
            if [[ "$repo_digests" == *" $remote_digest "* ]]; then
                echo "up-to-date"
            else
                echo "update-available"
            fi
            return
        fi

        # Fallback: `docker manifest inspect -v` yields the platform manifest
        # digest and its config digest (parsed with jq or python3).
        local manifest fields=""
        manifest=$(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect -v "$image" 2>/dev/null) \
            || { echo "?"; return; }
        if command -v jq &>/dev/null; then
            fields=$(jq -r --arg os "$os" --arg arch "$arch" '
                (if type == "array" then "list" else "single" end) as $kind
                | [if type == "array" then .[] else . end
                   | select($kind == "single"
                       or (.Descriptor.platform.os == $os
                           and .Descriptor.platform.architecture == $arch))][0]
                | [$kind, (.Descriptor.digest // ""),
                   ((.SchemaV2Manifest // .OCIManifest).config.digest // "")]
                | join(" ")' <<<"$manifest" 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            fields=$(python3 -c '
import sys, json
os_, arch = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
kind = "list" if isinstance(data, list) else "single"
for e in (data if kind == "list" else [data]):
    d = e.get("Descriptor") or {}
    p = d.get("platform") or {}
    if kind == "single" or (p.get("os") == os_ and p.get("architecture") == arch):
        m = e.get("SchemaV2Manifest") or e.get("OCIManifest") or {}
        print(kind, d.get("digest", ""), (m.get("config") or {}).get("digest", ""))
        break
' "$os" "$arch" <<<"$manifest" 2>/dev/null)
        fi

        local kind plat_digest config_digest
        read -r kind plat_digest config_digest <<<"$fields"
        [[ "$plat_digest" == sha256:* ]] || { echo "?"; return; }

        if [[ "$repo_digests" == *" $plat_digest "* || "$local_id" == "$config_digest" ]]; then
            echo "up-to-date"
        elif [[ "$kind" == "single" ]]; then
            # A single manifest's digest is the top-level digest: a mismatch is real
            echo "update-available"
        elif [[ -n "$config_digest" && "$repo_digests" != *" $local_id "* ]]; then
            # Classic image store: the image ID is the config digest
            echo "update-available"
        else
            # containerd store with a multi-arch index: cannot tell without buildx
            echo "?"
        fi
    }

    # Interactive update TUI: check images, present checklist, pull selections.
    _dports_update() {
        local image
        local UC_RESET UC_BOLD UC_DIM UC_CYAN UC_GREEN UC_YELLOW UC_RED
        if [[ -t 1 ]]; then
            UC_RESET='\033[0m'; UC_BOLD='\033[1m'; UC_DIM='\033[2m'
            UC_CYAN='\033[36m'; UC_GREEN='\033[32m'; UC_YELLOW='\033[33m'; UC_RED='\033[31m'
        fi

        if ! command -v docker &>/dev/null; then
            echo "Error: Docker is not installed or not in PATH" >&2; return 1
        fi
        local platform
        if ! platform=$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null); then
            echo "Error: Cannot connect to Docker daemon." >&2; return 1
        fi
        platform=$(echo "$platform" | sed 's/x86_64$/amd64/;s/aarch64$/arm64/;s/armv[0-9]*l$/arm/')

        # Use the reference each container was created from: `docker ps`
        # shows a bare image ID once the tag has moved to a newer image.
        local images=() container_ids
        container_ids=$(docker ps -q)
        if [[ -n "$container_ids" ]]; then
            # shellcheck disable=SC2086
            mapfile -t images < <(docker inspect --format '{{.Config.Image}}' $container_ids | sort -u)
        fi
        if [[ ${#images[@]} -eq 0 ]]; then
            echo "No running containers found." >&2; return 0
        fi

        # ── Check phase (parallel) ────────────────────────────────────────────
        printf "${UC_BOLD}Checking for image updates...${UC_RESET}\n\n"

        local tmpdir
        tmpdir=$(mktemp -d)

        printf "  Querying %d image(s) in parallel..." "${#images[@]}"
        # Background jobs run inside a subshell so an interactive shell
        # does not print job-control notices for each of them.
        (
            idx=0
            for image in "${images[@]}"; do
                _dports_check_image_update "$image" "$platform" > "$tmpdir/$idx" &
                (( idx++ ))
            done
            wait
        )
        printf " done.\n\n"

        local -A img_status
        local idx=0 st
        for image in "${images[@]}"; do
            st=$(cat "$tmpdir/$idx" 2>/dev/null)
            img_status["$image"]="${st:-?}"
            case "$st" in
                update-available) printf "  %-45s ${UC_YELLOW}[UPDATE AVAILABLE]${UC_RESET}\n" "$image" ;;
                up-to-date)       printf "  %-45s ${UC_GREEN}[OK]${UC_RESET}\n" "$image" ;;
                pinned)           printf "  %-45s ${UC_DIM}[PINNED]${UC_RESET}\n" "$image" ;;
                *)                printf "  %-45s ${UC_DIM}[?]${UC_RESET}\n" "$image" ;;
            esac
            (( idx++ ))
        done
        rm -rf "$tmpdir"
        echo

        # ── Selection phase ──────────────────────────────────────────────────
        local selected=()
        local dialog_tool
        dialog_tool=$(_dports_update_get_dialog_tool)

        if [[ -n "$dialog_tool" && -t 0 && -t 1 ]]; then
            local items=()
            for image in "${images[@]}"; do
                local st="${img_status[$image]}" label state
                case "$st" in
                    update-available) label="[UPDATE AVAILABLE]"; state="ON"  ;;
                    up-to-date)       label="[Up to date]";        state="OFF" ;;
                    pinned)           label="[Pinned digest]";     state="OFF" ;;
                    *)                label="[Status unknown]";    state="ON"  ;;
                esac
                items+=("$image" "$label" "$state")
            done

            local num=${#images[@]}
            local height=$(( num + 9 ))
            (( height < 14 )) && height=14
            (( height > 30 )) && height=30

            local tmpfile
            tmpfile=$(mktemp)

            "$dialog_tool" \
                --title "dports update" \
                --checklist "Select images to pull:\n(SPACE=toggle  ENTER=confirm  ESC=cancel)" \
                "$height" 72 "$num" \
                "${items[@]}" \
                2>"$tmpfile"

            local ret=$?
            if [[ $ret -ne 0 ]]; then
                rm -f "$tmpfile"; echo "Cancelled."; return 0
            fi

            # whiptail prints "img1" "img2"; image references never contain
            # quotes or whitespace, so stripping the quotes is enough.
            local raw
            raw=$(cat "$tmpfile"); rm -f "$tmpfile"
            read -ra selected <<< "${raw//\"/}"
        else
            # Plain-text fallback
            printf "${UC_BOLD}Available images:${UC_RESET}\n"
            idx=1
            for image in "${images[@]}"; do
                local slabel
                case "${img_status[$image]}" in
                    update-available) slabel="${UC_YELLOW}[UPDATE]${UC_RESET}" ;;
                    up-to-date)       slabel="${UC_GREEN}[OK]${UC_RESET}" ;;
                    pinned)           slabel="${UC_DIM}[PINNED]${UC_RESET}" ;;
                    *)                slabel="${UC_DIM}[?]${UC_RESET}" ;;
                esac
                printf "  %2d) %s  %b\n" "$idx" "$image" "$slabel"
                (( idx++ ))
            done
            echo
            printf "Enter numbers (space-separated), 'a' for all with updates, 'q' to quit: "
            local input=""
            read -r input

            case "$input" in
                q|Q|"") echo "Cancelled."; return 0 ;;
                a|A)
                    for image in "${images[@]}"; do
                        case "${img_status[$image]}" in
                            up-to-date|pinned) ;;
                            *) selected+=("$image") ;;
                        esac
                    done
                    ;;
                *)
                    local choices=() num
                    read -ra choices <<< "$input"
                    for num in "${choices[@]}"; do
                        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#images[@]} )); then
                            selected+=("${images[$((num-1))]}")
                        fi
                    done
                    ;;
            esac
        fi

        if [[ ${#selected[@]} -eq 0 ]]; then
            echo "No images selected."; return 0
        fi

        # ── Pull phase ───────────────────────────────────────────────────────
        printf "\n${UC_BOLD}Pulling %d image(s)...${UC_RESET}\n\n" "${#selected[@]}"
        local n_updated=0 n_current=0 n_failed=0

        for image in "${selected[@]}"; do
            printf "${UC_CYAN}▸ %s${UC_RESET}\n" "$image"
            # Compare image IDs before/after instead of parsing pull output,
            # whose wording differs between image stores and Docker versions.
            local output before after
            before=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)
            if output=$(docker pull "$image" 2>&1); then
                after=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)
                if [[ "$before" != "$after" ]]; then
                    printf "  ${UC_GREEN}✔ Updated${UC_RESET}\n"
                    (( n_updated++ ))
                else
                    printf "  ${UC_GREEN}✔ Already up to date${UC_RESET}\n"
                    (( n_current++ ))
                fi
            else
                printf "  ${UC_RED}✗ Failed${UC_RESET}\n"
                echo "$output" | tail -3 | sed 's/^/    /'
                (( n_failed++ ))
            fi
            echo
        done

        # ── Summary ──────────────────────────────────────────────────────────
        printf "${UC_BOLD}─────────────────────${UC_RESET}\n"
        (( n_updated > 0 )) && printf "  ${UC_GREEN}✔ Updated:          %d${UC_RESET}\n" "$n_updated"
        (( n_current > 0 )) && printf "  ${UC_DIM}  Already current:   %d${UC_RESET}\n" "$n_current"
        (( n_failed  > 0 )) && printf "  ${UC_RED}✗ Failed:           %d${UC_RESET}\n" "$n_failed"
        if (( n_updated > 0 )); then
            printf "\n${UC_DIM}Running containers keep the old image until they are recreated\n"
            printf "(e.g. 'docker compose up -d' in the project directory).${UC_RESET}\n"
        fi
        (( n_failed == 0 ))
    }

    # ── Cloudflare Tunnel helpers ──────────────────────────────────────────────

    # Fetch a URL to stdout with short timeouts (curl or wget)
    _dports_http_get() {
        if command -v curl &>/dev/null; then
            curl -fsS --connect-timeout 1 --max-time 3 "$1" 2>/dev/null
        elif command -v wget &>/dev/null; then
            wget -qO- -T 3 -t 1 "$1" 2>/dev/null
        else
            return 1
        fi
    }

    # Print "hostname<TAB>path<TAB>service" for every ingress rule of a
    # cloudflared container.
    #   1. The metrics server's /config endpoint (works for locally and
    #      remotely managed tunnels); only when DIRECT=true, i.e. the host
    #      can reach container IPs (native Linux Docker).
    #   2. The config file inside the container, read with `docker cp`.
    #   3. A --url / TUNNEL_URL origin (quick tunnels, legacy mode).
    # Usage: _dports_tunnel_ingress CONTAINER DIRECT
    # Returns 1 if no rules could be read.
    _dports_tunnel_ingress() {
        local cf="$1" direct="$2"
        local -a argv=()
        local env metrics="" config="" url="" workdir netmode i a
        mapfile -t argv < <(docker inspect --format '{{range .Args}}{{.}}{{"\n"}}{{end}}' "$cf" 2>/dev/null)
        env=$(docker inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$cf" 2>/dev/null)
        for (( i = 0; i < ${#argv[@]}; i++ )); do
            a="${argv[i]}"
            case "$a" in
                --metrics=*) metrics="${a#*=}" ;;
                --metrics)   metrics="${argv[i+1]:-}" ;;
                --config=*)  config="${a#*=}" ;;
                --config)    config="${argv[i+1]:-}" ;;
                --url=*)     url="${a#*=}" ;;
                --url)       url="${argv[i+1]:-}" ;;
            esac
        done
        [[ -z "$metrics" ]] && metrics=$(sed -n 's/^TUNNEL_METRICS=//p' <<<"$env")
        [[ -z "$url" ]] && url=$(sed -n 's/^TUNNEL_URL=//p' <<<"$env")
        netmode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cf" 2>/dev/null)

        # 1. Metrics server
        if [[ "$direct" == true ]]; then
            local hosts ports host port json quick
            if [[ "$netmode" == host ]]; then
                hosts="127.0.0.1"
            else
                hosts=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cf" 2>/dev/null)
                # A loopback-only metrics address is unreachable from the host
                case "${metrics%:*}" in localhost|127.*|\[::1\]) hosts="" ;; esac
            fi
            if [[ -n "$metrics" ]]; then
                ports="${metrics##*:}"
            else
                ports="20241 20242 20243 20244 20245"
            fi
            for host in $hosts; do
                for port in $ports; do
                    json=$(_dports_http_get "http://$host:$port/config")
                    [[ "$json" == '{"version"'* ]] || continue
                    quick=""
                    [[ -n "$url" ]] && quick=$(_dports_http_get "http://$host:$port/quicktunnel" \
                        | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p')
                    # (awk code avoids "\\" so it is shared verbatim with dports.fish)
                    awk -v quick="$quick" '
                    function repl(s, from, to,    out, i) {
                        out = ""
                        while ((i = index(s, from)) > 0) {
                            out = out substr(s, 1, i - 1) to
                            s = substr(s, i + length(from))
                        }
                        return out s
                    }
                    function unesc(s,    bs) {
                        bs = sprintf("%c", 92)
                        s = repl(s, bs "u0026", "&"); s = repl(s, bs "u003c", "<")
                        s = repl(s, bs "u003e", ">")
                        return repl(s, bs bs, bs)
                    }
                    {
                        s = $0
                        while (match(s, /"hostname":"[^"]*","path":(null|"[^"]*"),"service":"[^"]*"/)) {
                            r = substr(s, RSTART, RLENGTH)
                            s = substr(s, RSTART + RLENGTH)
                            h = r; sub(/^"hostname":"/, "", h); sub(/".*/, "", h)
                            p = r; sub(/^"hostname":"[^"]*","path":/, "", p); sub(/,"service":".*/, "", p)
                            p = (p == "null") ? "" : substr(p, 2, length(p) - 2)
                            v = r; sub(/.*,"service":"/, "", v); v = substr(v, 1, length(v) - 1)
                            if (h == "" && quick != "") h = quick
                            printf "%s\t%s\t%s\n", unesc(h), unesc(p), unesc(v)
                        }
                    }' <<<"$json"
                    return 0
                done
            done
        fi

        # 2. Config file inside the container (docker cp works on distroless)
        local -a paths
        if [[ -n "$config" ]]; then
            if [[ "$config" != /* ]]; then
                workdir=$(docker inspect --format '{{.Config.WorkingDir}}' "$cf" 2>/dev/null)
                config="${workdir:-/}/$config"
            fi
            paths=("$config")
        else
            paths=(/etc/cloudflared/config.yml /etc/cloudflared/config.yaml
                   /home/nonroot/.cloudflared/config.yml /home/nonroot/.cloudflared/config.yaml
                   /root/.cloudflared/config.yml /root/.cloudflared/config.yaml)
        fi
        local p yaml="" rules=""
        for p in "${paths[@]}"; do
            yaml=$(docker cp "$cf:$p" - 2>/dev/null | tar -xOf - 2>/dev/null) && [[ -n "$yaml" ]] && break
        done
        if [[ -n "$yaml" ]]; then
            rules=$(awk '
            function unquote(v,    c) {
                sub(/^[ \t]+/, "", v); sub(/[ \t]+(#.*)?$/, "", v)
                c = substr(v, 1, 1)
                if (length(v) >= 2 && (c == "\"" || c == sprintf("%c", 39)) && substr(v, length(v)) == c)
                    v = substr(v, 2, length(v) - 2)
                return v
            }
            function flush() {
                if (svc != "") { printf "%s\t%s\t%s\n", host, path, svc; n_rules++ }
                host = ""; path = ""; svc = ""
            }
            /^ingress:[ \t]*$/ { ing = 1; next }
            ing && /^[^ \t#-]/ { flush(); ing = 0 }
            ing {
                line = $0
                if (line ~ /^[ \t]*-[ \t]/) { flush(); sub(/^[ \t]*-[ \t]*/, "", line) }
                if (line ~ /^[ \t]*(hostname|path|service):/) {
                    key = line; sub(/^[ \t]*/, "", key); sub(/:.*/, "", key)
                    val = line; sub(/^[^:]*:/, "", val); val = unquote(val)
                    if (key == "hostname") host = val
                    else if (key == "path") path = val
                    else svc = val
                }
                next
            }
            # Legacy single-service config: top-level hostname/url
            /^hostname:/ { v = $0; sub(/^hostname:/, "", v); lhost = unquote(v) }
            /^url:/      { v = $0; sub(/^url:/, "", v); lurl = unquote(v) }
            END {
                flush()
                if (!n_rules && lurl != "") printf "%s\t\t%s\n", lhost, lurl
            }' <<<"$yaml")
        fi
        # 3. --url origin (quick tunnel or legacy flag-only setup)
        [[ -z "$rules" && -n "$url" ]] && rules=$(printf '\t\t%s' "$url")
        [[ -n "$rules" ]] || return 1
        printf '%s\n' "$rules"
    }

    # Print the Cloudflare Tunnel routes table (or JSON / hostnames).
    # Each ingress rule is matched to the container its service points at,
    # by container name, compose service, network alias, hostname or IP on
    # a network shared with cloudflared.
    _dports_tunnel_section() {
        local cfs
        cfs=$(docker ps --no-trunc --format '{{.Names}}\t{{.Image}}\t{{.Command}}' 2>/dev/null \
            | awk -F'\t' 'tolower($2) ~ /cloudflared/ || $3 ~ /cloudflared/ { print $1 }')

        # Can the host reach container IPs? Not on Docker Desktop, rootless
        # Docker or a remote daemon.
        local direct=false info endpoint
        if [[ "$(uname -s)" == Linux ]]; then
            endpoint="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)}"
            info=$(docker info --format '{{.OperatingSystem}} {{.SecurityOptions}}' 2>/dev/null)
            if [[ ( -z "$endpoint" || "$endpoint" == unix://* ) \
                && "$info" != *"Docker Desktop"* && "$info" != *rootless* ]]; then
                direct=true
            fi
        fi

        local stream="" ids cf rules cf_id cf_mode cf_nets
        ids=$(docker ps -q)
        if [[ -n "$cfs" && -n "$ids" ]]; then
            # Identity of every running container (I), containers sharing
            # another container's network namespace (S), published ports (P)
            # shellcheck disable=SC2086
            stream=$(docker inspect --format '{{$n := slice .Name 1}}{{$i := .Config.Image}}{{if eq (printf "%.10s" .HostConfig.NetworkMode) "container:"}}S{{"\t"}}{{.HostConfig.NetworkMode}}{{"\t"}}{{$n}}{{"\t"}}{{$i}}{{"\n"}}{{end}}{{$h := .Config.Hostname}}{{$s := index .Config.Labels "com.docker.compose.service"}}{{range $net, $c := .NetworkSettings.Networks}}I{{"\t"}}{{$n}}{{"\t"}}{{$i}}{{"\t"}}{{$net}}{{"\t"}}{{$c.IPAddress}}{{"\t"}}{{$n}} {{$h}} {{$s}} {{join $c.Aliases " "}}{{"\n"}}{{end}}' $ids 2>/dev/null)
            stream+=$'\n'$(docker ps --format '{{.Ports}}\t{{.Names}}\t{{.Image}}' | awk -F'\t' '{
                n = split($1, ports, ", ")
                for (i = 1; i <= n; i++) if (ports[i] ~ /->/) {
                    split(ports[i], m, "->"); hp = m[1]
                    gsub(/^\[?[0-9a-fA-F.:]*\]?:/, "", hp)
                    printf "P\t%s\t%s\t%s\n", hp, $2, $3
                }
            }')
            while IFS= read -r cf; do
                [[ -n "$cf" ]] || continue
                if ! rules=$(_dports_tunnel_ingress "$cf" "$direct"); then
                    echo "Note: cannot read the ingress rules of '$cf'" \
                        "(no config file in the container, and its metrics server is not reachable from this host)." >&2
                    continue
                fi
                cf_id=$(docker inspect --format '{{.Id}}' "$cf")
                cf_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cf")
                if [[ "$cf_mode" == container:* ]]; then
                    cf_mode="container:$(docker inspect --format '{{slice .Name 1}}' "${cf_mode#container:}" 2>/dev/null)"
                fi
                cf_nets=$(docker inspect --format '{{range $net, $c := .NetworkSettings.Networks}}{{$net}},{{end}}' "$cf")
                stream+=$'\n'$(awk -F'\t' -v cf="$cf" -v id="$cf_id" -v mode="$cf_mode" -v nets="$cf_nets" \
                    '{ printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cf, id, mode, nets, $1, $2, $3 }' <<<"$rules")
            done <<<"$cfs"
        fi

        local results
        results=$(printf '%s\n' "$stream" | awk -F'\t' \
            -v filter_port="$filter_port" \
            -v filter_name="$filter_name" \
            -v filter_image="$filter_image" '
            $1 == "I" {
                split($6, names, " ")
                for (k in names) if (names[k] != "") {
                    byname[$4 SUBSEP names[k]] = $2; image[$2] = $3
                }
                if ($5 != "") byip[$5] = $2
                image[$2] = $3
                next
            }
            $1 == "S" { shared[$2] = $3; image[$3] = $4; next }
            $1 == "P" { if (!($2 in published)) { published[$2] = $3; image[$3] = $4 }; next }
            $1 == "R" {
                cf = $2; id = $3; mode = $4; nets = $5; hostname = $6; path = $7; svc = $8
                if (svc ~ /^http_status:/) next          # catch-all 404 etc.
                name = ""; port = ""; proto = svc
                if (svc ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) {
                    proto = svc; sub(/:\/\/.*/, "", proto); proto = tolower(proto)
                    hp = svc; sub(/^[^:]*:\/\//, "", hp); sub(/\/.*/, "", hp)
                    host = hp; port = ""
                    if (hp ~ /^\[/) {                        # [IPv6]:port
                        host = hp; sub(/\].*/, "]", host)
                        port = hp; sub(/^\[[^]]*\]:?/, "", port)
                    } else if (hp ~ /:/) {
                        host = hp; sub(/:.*/, "", host)
                        port = hp; sub(/^[^:]*:/, "", port)
                    }
                    if (port == "") {
                        if (proto == "http" || proto == "ws") port = "80"
                        else if (proto == "https" || proto == "wss") port = "443"
                        else if (proto == "ssh") port = "22"
                        else if (proto == "rdp") port = "3389"
                        else if (proto == "smb") port = "445"
                    }
                    lhost = tolower(host)
                    if (lhost == "localhost" || lhost ~ /^127\./ || lhost == "[::1]") {
                        if (mode ~ /^container:/) name = substr(mode, 11)
                        else if (mode == "host") name = published[port]
                        else if (("container:" id) in shared) name = shared["container:" id]
                    } else if (lhost == "host.docker.internal" || lhost == "host.containers.internal" \
                               || lhost == "172.17.0.1") {
                        name = published[port]
                    } else if (host in byip) {
                        name = byip[host]
                    } else {
                        n = split(nets, netlist, ",")
                        for (k = 1; k <= n && name == ""; k++)
                            if ((netlist[k] SUBSEP host) in byname) name = byname[netlist[k] SUBSEP host]
                    }
                    if (name == "") name = "(" host ")"
                } else {
                    name = "(" svc ")"                      # hello_world, unix:... etc.
                }
                img = (name in image) ? image[name] : "-"
                if (filter_name != "" && index(tolower(name), tolower(filter_name)) == 0) next
                if (filter_image != "" && index(tolower(img), tolower(filter_image)) == 0) next
                if (filter_port != "" && port != filter_port) next
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                    (hostname == "" ? "*" : hostname), path, name, img, port, proto, svc, cf
            }' | sort -t$'\t' -k1,1 -k2,2 | uniq)

        if [[ -z "$results" ]]; then
            if [[ "$json_output" == true ]]; then
                echo "[]"
            elif [[ -z "$cfs" ]]; then
                echo "No running cloudflared containers found." >&2
            elif [[ -n "$filter_port" || -n "$filter_name" || -n "$filter_image" ]]; then
                echo "No tunnel routes match the specified filters." >&2
            else
                echo "No Cloudflare Tunnel routes found." >&2
            fi
            return 0
        fi

        if [[ "$quiet" == true ]]; then
            cut -f1 <<<"$results" | uniq
        elif [[ "$json_output" == true ]]; then
            awk -F'\t' '
            function repl(s, from, to,    out, i) {
                out = ""
                while ((i = index(s, from)) > 0) {
                    out = out substr(s, 1, i - 1) to
                    s = substr(s, i + length(from))
                }
                return out s
            }
            function q(s,    bs) {
                bs = sprintf("%c", 92)
                s = repl(s, bs, bs bs); s = repl(s, "\"", bs "\"")
                return "\"" s "\""
            }
            BEGIN { print "[" }
            {
                name = ($3 ~ /^\(/) ? "" : $3; img = ($4 == "-") ? "" : $4
                line = sprintf("  {\"hostname\": %s, \"path\": %s, \"name\": %s, \"image\": %s, \"port\": %s, \"protocol\": %s, \"service\": %s, \"tunnel\": %s}", \
                    q($1), ($2 == "" ? "null" : q($2)), q(name), q(img), q($5), q($6), q($7), q($8))
                if (NR > 1) print prev ","
                prev = line
            }
            END { if (NR) print prev; print "]" }' <<<"$results"
        else
            local hostname path name img port proto svc tunnel target
            if [[ "$verbose" == true ]]; then
                printf "${C_BOLD}%-32s  %-24s  %-30s  %-16s  %s${C_RESET}\n" "HOSTNAME" "NAME" "SERVICE" "TUNNEL" "IMAGE"
                printf "${C_DIM}%-32s  %-24s  %-30s  %-16s  %s${C_RESET}\n" \
                    "────────────────────────────────" "────────────────────────" \
                    "──────────────────────────────" "────────────────" "────────────────────────"
            else
                printf "${C_BOLD}%-32s  %-24s  %-12s  %s${C_RESET}\n" "HOSTNAME" "NAME" "TARGET" "IMAGE"
                printf "${C_DIM}%-32s  %-24s  %-12s  %s${C_RESET}\n" \
                    "────────────────────────────────" "────────────────────────" "────────────" "────────────────────────"
            fi
            # Read with a non-whitespace separator so empty fields are kept
            while IFS=$'\037' read -r hostname path name img port proto svc tunnel; do
                [[ -n "$path" ]] && hostname="$hostname $path"
                if [[ "$verbose" == true ]]; then
                    printf "${C_GREEN}%-32s${C_RESET}  ${C_CYAN}%-24s${C_RESET}  ${C_YELLOW}%-30s${C_RESET}  %-16s  %s\n" \
                        "$hostname" "$name" "$svc" "$tunnel" "$img"
                else
                    target="${port:+$port/}$proto"
                    printf "${C_GREEN}%-32s${C_RESET}  ${C_CYAN}%-24s${C_RESET}  ${C_YELLOW}%-12s${C_RESET}  %s\n" \
                        "$hostname" "$name" "$target" "$img"
                fi
            done < <(tr '\t' '\037' <<<"$results")
        fi
    }

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                verbose=true
                shift
                ;;
            -a|--all)
                show_all=true
                shift
                ;;
            -p|--port)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --port requires a port number" >&2
                    return 1
                fi
                filter_port="$2"
                shift 2
                ;;
            -n|--name)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --name requires a name pattern" >&2
                    return 1
                fi
                filter_name="$2"
                shift 2
                ;;
            -i|--image)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --image requires an image pattern" >&2
                    return 1
                fi
                filter_image="$2"
                shift 2
                ;;
            -c|--color)
                C_RESET='\033[0m'
                C_BOLD='\033[1m'
                C_DIM='\033[2m'
                C_CYAN='\033[36m'
                C_GREEN='\033[32m'
                C_YELLOW='\033[33m'
                shift
                ;;
            -C|--no-color)
                C_RESET=''
                C_BOLD=''
                C_DIM=''
                C_CYAN=''
                C_GREEN=''
                C_YELLOW=''
                shift
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -t|--tunnel)
                show_tunnel=true
                shift
                ;;
            -h|--help)
                _dports_usage
                return 0
                ;;
            -V|--version)
                echo "dports version $DPORTS_VERSION"
                return 0
                ;;
            update)
                _dports_update
                return $?
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                echo "Run 'dports --help' for usage information." >&2
                return 1
                ;;
            *)
                echo "Error: Unexpected argument: $1" >&2
                echo "Run 'dports --help' for usage information." >&2
                return 1
                ;;
        esac
    done

    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        echo "Error: Docker is not installed or not in PATH" >&2
        return 1
    fi

    if ! docker info &>/dev/null; then
        echo "Error: Cannot connect to Docker daemon." >&2
        echo "Is Docker running? Do you have permission to access it?" >&2
        return 1
    fi

    # With -q/-j, --tunnel prints only the tunnel routes (one kind of record)
    if [[ "$show_tunnel" == true && ( "$quiet" == true || "$json_output" == true ) ]]; then
        _dports_tunnel_section
        return
    fi

    # Get container data
    local data
    data=$(docker ps --format "{{.Ports}}\t{{.Names}}\t{{.Image}}" 2>/dev/null)

    # Stopped containers have an empty Ports column in `docker ps -a`,
    # so read their configured bindings from `docker inspect` instead.
    if [[ "$show_all" == true ]]; then
        local stopped_ids stopped
        stopped_ids=$(docker ps -aq --filter status=created --filter status=exited --filter status=dead 2>/dev/null)
        if [[ -n "$stopped_ids" ]]; then
            # shellcheck disable=SC2086
            stopped=$(docker inspect --format \
                '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{if .HostPort}}{{.HostIp}}:{{.HostPort}}->{{$p}}, {{end}}{{end}}{{end}}{{"\t"}}{{slice .Name 1}}{{"\t"}}{{.Config.Image}}' \
                $stopped_ids 2>/dev/null)
            data=$(printf '%s\n%s' "$data" "$stopped" | sed '/^$/d')
        fi
    fi

    if [[ -z "$data" ]]; then
        if [[ "$json_output" == true ]]; then
            echo "[]"
        else
            echo "No containers found." >&2
        fi
        [[ "$show_tunnel" == true ]] && _dports_tunnel_section
        return 0
    fi

    # Process and filter data with AWK
    local results
    results=$(echo "$data" | awk -F"\t" \
        -v verbose="$verbose" \
        -v filter_port="$filter_port" \
        -v filter_name="$filter_name" \
        -v filter_image="$filter_image" \
        -v quiet="$quiet" \
        -v json="$json_output" \
    'BEGIN {
        if (json == "true") first = 1
    }
    {
        # Skip if name filter does not match (case-insensitive)
        if (filter_name != "" && index(tolower($2), tolower(filter_name)) == 0) next
        # Skip if image filter does not match (case-insensitive)
        if (filter_image != "" && index(tolower($3), tolower(filter_image)) == 0) next

        # Split multiple port mappings
        n = split($1, ports, ", ")
        for (i = 1; i <= n; i++) {
            if (ports[i] ~ /->/) {
                # Parse port mapping: [host:]port->container_port/protocol
                split(ports[i], mapping, "->")
                
                # Extract host port (handle IPv4/IPv6: 0.0.0.0:8080 or :::8080)
                host_part = mapping[1]
                gsub(/^\[?[0-9a-fA-F.:]*\]?:/, "", host_part)
                host_port = host_part
                
                # Extract container port and protocol
                container_port = mapping[2]
                
                # Apply port filter (exact match)
                if (filter_port != "" && host_port != filter_port) continue

                if (quiet == "true") {
                    print host_port
                } else if (json == "true") {
                    printf "%s\t%s\t%s\t%s\n", host_port, $2, container_port, $3
                } else if (verbose == "true") {
                    printf "%s\t%s\t%s\t%s\n", host_port, $2, container_port, $3
                } else {
                    printf "%s\t%s\t%s\n", host_port, $2, $3
                }
            }
        }
    }' | sort -t$'\t' -k1 -V | uniq)

    # Handle empty results
    if [[ -z "$results" ]]; then
        if [[ "$json_output" == true ]]; then
            echo "[]"
        elif [[ -n "$filter_port" || -n "$filter_name" || -n "$filter_image" ]]; then
            echo "No containers match the specified filters." >&2
        else
            echo "No containers with exposed ports found." >&2
        fi
        [[ "$show_tunnel" == true ]] && _dports_tunnel_section
        return 0
    fi

    # Output formatting
    if [[ "$quiet" == true ]]; then
        # Quiet mode: just port numbers
        echo "$results"
    elif [[ "$json_output" == true ]]; then
        # JSON output
        echo "["
        local prev=""
        while IFS=$'\t' read -r port name internal image; do
            local line
            line=$(printf '  {"port": "%s", "name": "%s", "internal": "%s", "image": "%s"}' \
                "$port" "$name" "$internal" "$image")
            if [[ -n "$prev" ]]; then
                printf '%s,\n' "$prev"
            fi
            prev="$line"
        done <<< "$results"
        if [[ -n "$prev" ]]; then
            printf '%s\n' "$prev"
        fi
        echo "]"
    elif [[ "$verbose" == true ]]; then
        # Verbose mode with internal port
        printf "${C_BOLD}%-8s  %-28s  %-15s  %s${C_RESET}\n" "PORT" "NAME" "INTERNAL" "IMAGE"
        printf "${C_DIM}%-8s  %-28s  %-15s  %s${C_RESET}\n" \
            "────────" "────────────────────────────" "───────────────" "────────────────────────"
        echo "$results" | while IFS=$'\t' read -r port name internal image; do
            printf "${C_GREEN}%-8s${C_RESET}  ${C_CYAN}%-28s${C_RESET}  ${C_YELLOW}%-15s${C_RESET}  %s\n" \
                "$port" "$name" "$internal" "$image"
        done
    else
        # Standard mode
        printf "${C_BOLD}%-8s  %-28s  %s${C_RESET}\n" "PORT" "NAME" "IMAGE"
        printf "${C_DIM}%-8s  %-28s  %s${C_RESET}\n" \
            "────────" "────────────────────────────" "────────────────────────"
        echo "$results" | while IFS=$'\t' read -r port name image; do
            printf "${C_GREEN}%-8s${C_RESET}  ${C_CYAN}%-28s${C_RESET}  %s\n" \
                "$port" "$name" "$image"
        done
    fi

    if [[ "$show_tunnel" == true ]]; then
        echo
        _dports_tunnel_section
    fi
}

# If script is executed directly (not sourced), run dports with arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    dports "$@"
fi
