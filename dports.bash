#!/usr/bin/env bash
#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.4.1
# License: MIT
#
# Installation:
#   Bash: Copy to ~/.bash_functions/dports and source from ~/.bashrc
#   Or:   Source this file directly in ~/.bashrc
#   Apt:  sudo apt install dports  (Forgejo package registry)
#

DPORTS_VERSION="2.4.1"

dports() {
    # Colors (disabled if not a terminal)
    local C_RESET C_BOLD C_DIM C_CYAN C_GREEN C_YELLOW C_RED
    if [[ -t 1 ]]; then
        C_RESET='\033[0m'
        C_BOLD='\033[1m'
        C_DIM='\033[2m'
        C_CYAN='\033[36m'
        C_GREEN='\033[32m'
        C_YELLOW='\033[33m'
        C_RED='\033[31m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED=''
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
    dports update [--check | --yes]

SUBCOMMANDS:
    update              Check running containers' images for updates and pick
                        which to pull (see 'dports update --help')

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
    dports update --check       Only report which images have updates
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

    _dports_update_usage() {
        cat <<'EOF'
dports update - Check running containers' images for updates and pull them

USAGE:
    dports update [OPTIONS]

OPTIONS:
    --check             Only report the status of each image; pull nothing
    -y, --yes           Pull every image that has an update, without asking
    -c, --color         Force color output
    -C, --no-color      Disable color output
    -h, --help          Show this help message

STATUS:
    update      The registry has a newer image (selected by default)
    current     The local image matches the registry
    pinned      Referenced by digest, so pulling never changes it
    local       Built locally or loaded from a file (not in the registry)
    unknown     The registry could not be asked or gave no clear answer

KEYS (interactive checklist):
    Up/Down, j/k        Move          PgUp/PgDn, Home/End  Jump
    Space               Toggle        u  Select images with updates
    a / n               Select all / none
    Enter               Pull the selected images
    q, Esc              Quit without pulling

Without a terminal, dports update only prints the report (like --check).
EOF
    }

    # Run a registry query with a time limit, so one unreachable registry
    # cannot stall the whole check (DPORTS_TIMEOUT seconds, default 30).
    _dports_registry() {
        if command -v timeout &>/dev/null; then
            timeout "${DPORTS_TIMEOUT:-30}" "$@"
        else
            "$@"
        fi
    }

    # Check whether a single image has an available update.
    # Compares the digests recorded when the image was pulled (RepoDigests)
    # against the registry, which works with both the classic and the
    # containerd image store.
    # Usage: _dports_check_image_update IMAGE [OS/ARCH[/VARIANT]]
    # Prints one line: STATUS<TAB>DETAIL (see _dports_update_usage)
    _dports_check_image_update() {
        local image="$1" platform="${2:-linux/amd64}"
        local os arch variant
        IFS=/ read -r os arch variant <<<"$platform"

        if [[ "$image" == *@sha256:* ]]; then
            printf 'pinned\tReferenced by digest, so pulling never changes it\n'; return
        fi
        if [[ "$image" == sha256:* || "$image" =~ ^[0-9a-f]{64}$ ]]; then
            printf 'local\tThe container was created from an image ID, not a name\n'; return
        fi

        local inspect local_id repo_digests=" " ref
        if ! inspect=$(docker image inspect "$image" \
                --format '{{.Id}}{{range .RepoDigests}} {{.}}{{end}}' 2>/dev/null) || [[ -z "$inspect" ]]; then
            printf 'unknown\tThe image is no longer present locally\n'; return
        fi
        local_id="${inspect%% *}"
        for ref in ${inspect#"$local_id"}; do
            repo_digests+="${ref##*@} "
        done
        if [[ "$repo_digests" == " " ]]; then
            printf 'local\tNo registry digest: built locally or loaded from a file\n'; return
        fi

        # Preferred: buildx reports the top-level (index) digest directly.
        # Parse its default output: older buildx releases ignore --format.
        local remote_digest="" out rc errs="" err_rc=0
        if docker buildx version &>/dev/null; then
            out=$(_dports_registry docker buildx imagetools inspect "$image" 2>&1); rc=$?
            remote_digest=$(awk '$1 == "Digest:" { print $2; exit }' <<<"$out")
            [[ "$remote_digest" == sha256:* ]] || { errs="$out"; err_rc=$rc; }
        fi
        if [[ "$remote_digest" == sha256:* ]]; then
            if [[ "$repo_digests" == *" $remote_digest "* ]]; then
                printf 'current\tMatches the registry\n'
            else
                printf 'update\tThe registry has a newer image\n'
            fi
            return
        fi

        # Fallback: `docker manifest inspect -v` yields the platform manifest
        # digest and its config digest (parsed with jq or python3).
        local manifest fields=""
        manifest=$(DOCKER_CLI_EXPERIMENTAL=enabled _dports_registry \
            docker manifest inspect -v "$image" 2>&1); rc=$?
        if (( rc != 0 )) || [[ "${manifest:0:1}" != "[" && "${manifest:0:1}" != "{" ]]; then
            (( rc == 124 )) && err_rc=124
            _dports_registry_error "$image" "$errs"$'\n'"$manifest" "$err_rc"
            return
        fi
        if command -v jq &>/dev/null; then
            fields=$(jq -r --arg os "$os" --arg arch "$arch" --arg variant "$variant" '
                (if type == "array" then "list" else "single" end) as $kind
                | [if type == "array" then .[] else . end
                   | select($kind == "single"
                       or (.Descriptor.platform.os == $os
                           and .Descriptor.platform.architecture == $arch
                           and ($variant == ""
                                or (.Descriptor.platform.variant // "") == $variant)))][0]
                | [$kind, (.Descriptor.digest // ""),
                   ((.SchemaV2Manifest // .OCIManifest).config.digest // "")]
                | join(" ")' <<<"$manifest" 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            fields=$(python3 -c '
import sys, json
os_, arch, variant = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(sys.stdin)
kind = "list" if isinstance(data, list) else "single"
for e in (data if kind == "list" else [data]):
    d = e.get("Descriptor") or {}
    p = d.get("platform") or {}
    if kind == "single" or (p.get("os") == os_ and p.get("architecture") == arch
                            and (not variant or p.get("variant", "") == variant)):
        m = e.get("SchemaV2Manifest") or e.get("OCIManifest") or {}
        print(kind, d.get("digest", ""), (m.get("config") or {}).get("digest", ""))
        break
' "$os" "$arch" "$variant" <<<"$manifest" 2>/dev/null)
        else
            printf 'unknown\tInstall docker buildx, jq or python3 to compare digests\n'; return
        fi

        local kind plat_digest config_digest
        read -r kind plat_digest config_digest <<<"$fields"
        if [[ "$plat_digest" != sha256:* ]]; then
            printf 'unknown\tThe registry has no manifest for %s\n' "$platform"; return
        fi

        if [[ "$repo_digests" == *" $plat_digest "* || "$local_id" == "$config_digest" ]]; then
            printf 'current\tMatches the registry\n'
        elif [[ "$kind" == "single" ]]; then
            # A single manifest's digest is the top-level digest: a mismatch is real
            printf 'update\tThe registry has a newer image\n'
        elif [[ -n "$config_digest" && "$repo_digests" != *" $local_id "* ]]; then
            # Classic image store: the image ID is the config digest
            printf 'update\tThe registry has a newer image\n'
        else
            printf 'unknown\tMulti-platform image on the containerd store: install docker buildx for an exact answer\n'
        fi
    }

    # Turn a failed registry query into STATUS<TAB>DETAIL.
    # Usage: _dports_registry_error IMAGE MESSAGES EXIT_STATUS
    _dports_registry_error() {
        local image="$1" msg="$2" rc="$3" first host="docker.io" official=false
        first="${image%%/*}"
        if [[ "$image" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
            host="$first"
        fi
        # Docker Hub's library namespace only holds public official images
        if [[ "$host" == docker.io && ( "$image" != */* || "$image" == library/* || "$image" == docker.io/library/* ) ]]; then
            official=true
        fi
        if (( rc == 124 )); then
            printf 'unknown\tNo answer from %s within %s s (DPORTS_TIMEOUT)\n' "$host" "${DPORTS_TIMEOUT:-30}"
        elif [[ "$msg" == *toomanyrequests* || "$msg" == *"rate limit"* ]]; then
            printf 'unknown\tDocker Hub rate limit reached; docker login raises it\n'
        elif [[ "$msg" == *"manifest unknown"* || "$msg" == *"not found"* || "$msg" == *"name unknown"* ]]; then
            printf 'local\tNot in the registry: built locally, or removed upstream\n'
        elif [[ "$msg" == *denied* || "$msg" == *nauthorized* || "$msg" == *insufficient_scope* \
                || "$msg" == *"authorization failed"* || "$msg" == *"does not exist"* \
                || "$msg" == *"401 "* || "$msg" == *"403 "* ]]; then
            if [[ "$official" == true ]]; then
                printf 'local\tNot on Docker Hub: built locally\n'
            else
                printf 'unknown\tAccess denied: private image? (docker login %s)\n' "$host"
            fi
        elif [[ "$msg" == *"no such host"* || "$msg" == *"dial tcp"* || "$msg" == *"i/o timeout"* \
                || "$msg" == *"connection refused"* || "$msg" == *"network is unreachable"* ]]; then
            printf 'unknown\t%s is unreachable\n' "$host"
        else
            msg=$(grep -m1 . <<<"$msg")
            printf 'unknown\tRegistry query failed: %s\n' "${msg:0:120}"
        fi
    }

    # _dports_fit VAR TEXT WIDTH: store TEXT cut or padded to WIDTH columns in VAR
    _dports_fit() {
        local __fit_s="$2" __fit_w="$3"
        if (( __fit_w <= 0 )); then printf -v "$1" '%s' ''; return; fi
        if (( ${#__fit_s} > __fit_w )); then
            __fit_s="${__fit_s:0:__fit_w-1}${_dports_ell:-~}"
        fi
        printf -v "$1" '%s%*s' "$__fit_s" $(( __fit_w - ${#__fit_s} )) ''
    }

    # Full-screen checklist. Reads the images/st/detail/users arrays of
    # _dports_update and prints the chosen indices, one per line.
    # Exit status: 0 confirmed, 1 cancelled, 2 no usable terminal.
    # Always run it in a subshell ($(...)): its traps and terminal settings
    # must never leak into the calling shell.
    _dports_update_tui() {
        exec 3<>/dev/tty 2>/dev/null || return 2
        local n=${#images[@]} cur=0 top=0 page=1 i key c rest rc msg="" saved
        local -a sel=()
        for (( i = 0; i < n; i++ )); do
            if [[ "${st[i]}" == update ]]; then sel[i]=1; else sel[i]=0; fi
        done

        local e=$'\033' t_rev t_bold t_dim t_reset t_green t_yellow t_cyan t_red
        t_rev="${e}[7m" t_reset="${e}[0m"
        if [[ -n "$C_RESET" ]]; then
            t_bold="${e}[1m" t_dim="${e}[2m" t_green="${e}[32m" t_yellow="${e}[33m" t_cyan="${e}[36m" t_red="${e}[31m"
        fi
        _dports_ell='~'
        [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]*8* ]] && _dports_ell='…'

        saved=$(stty -g <&3 2>/dev/null)
        # shellcheck disable=SC2064  # expand $saved now
        trap "printf '${e}[?25h${e}[?1049l' >&3; stty '$saved' <&3 2>/dev/null" EXIT
        # Ctrl+C still raises SIGINT (`read -n` re-enables signal keys):
        # exit through the EXIT trap so the terminal is always restored
        trap 'exit 1' INT TERM HUP
        stty -echo -icanon <&3 2>/dev/null
        printf '%s' "${e}[?1049h${e}[?25l" >&3

        local maxlen=5
        for (( i = 0; i < n; i++ )); do (( ${#images[i]} > maxlen )) && maxlen=${#images[i]}; done

        _dports_tui_status_color() {
            case "$1" in
                update)  printf '%s' "$t_yellow" ;;
                current) printf '%s' "$t_green" ;;
                local)   printf '%s' "$t_cyan" ;;
                unknown) printf '%s' "$t_red" ;;
                *)       printf '%s' "$t_dim" ;;
            esac
        }

        _dports_tui_draw() {
            local size rows cols list_h img_w users_w r line mark f_img f_st f_us n_sel=0 n_upd=0
            size=$(stty size <&3 2>/dev/null)
            rows=${size% *} cols=${size#* }
            [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ && "$rows" -gt 0 ]] || { rows=24 cols=80; }
            (( cols -= 1 ))                 # never write into the last column
            list_h=$(( rows - 8 )); (( list_h < 1 )) && list_h=1
            page=$list_h
            (( cur < top )) && top=$cur
            (( cur >= top + list_h )) && top=$(( cur - list_h + 1 ))
            (( top > n - list_h )) && top=$(( n - list_h ))
            (( top < 0 )) && top=0

            img_w=$(( cols - 22 - 12 )); (( img_w > maxlen )) && img_w=$maxlen; (( img_w < 10 )) && img_w=10
            users_w=$(( cols - 22 - img_w ))
            for (( r = 0; r < n; r++ )); do
                (( sel[r] )) && (( n_sel++ ))
                [[ "${st[r]}" == update ]] && (( n_upd++ ))
            done

            local rule frame="" title right
            printf -v rule '%*s' "$cols" ''; rule="${rule// /─}"
            right="$n_upd update(s) · $n_sel selected · $(( cur + 1 ))/$n"
            _dports_fit title " dports update" $(( cols - ${#right} - 1 ))
            frame+="$t_bold$title$t_reset $right${e}[K"$'\n'
            frame+="$t_dim$rule$t_reset${e}[K"$'\n'
            _dports_fit f_img "IMAGE" "$img_w"; _dports_fit f_st "STATUS" 7; _dports_fit f_us "CONTAINERS" "$users_w"
            frame+="$t_dim      $f_img  $f_st  $f_us$t_reset${e}[K"$'\n'

            for (( r = 0; r < list_h; r++ )); do
                i=$(( top + r ))
                line=""
                if (( i < n )); then
                    mark="[ ]"; (( sel[i] )) && mark="[x]"
                    _dports_fit f_img "${images[i]}" "$img_w"
                    _dports_fit f_st "${st[i]}" 7
                    _dports_fit f_us "${users[i]}" "$users_w"
                    if (( i == cur )); then
                        line="$t_rev> $mark $f_img  $f_st  $f_us$t_reset"
                    else
                        line="  $mark $f_img  $(_dports_tui_status_color "${st[i]}")$f_st$t_reset  $t_dim$f_us$t_reset"
                    fi
                fi
                frame+="$line${e}[K"$'\n'
            done

            local more=""
            (( top > 0 )) && more+="↑ "
            (( top + list_h < n )) && more+="↓ more"
            _dports_fit line "$more" "$cols"
            frame+="$t_dim$line$t_reset${e}[K"$'\n'
            frame+="$t_dim$rule$t_reset${e}[K"$'\n'
            _dports_fit line " ${images[cur]}: ${detail[cur]}" "$cols"
            frame+="$(_dports_tui_status_color "${st[cur]}")$line$t_reset${e}[K"$'\n'
            _dports_fit line " Used by: ${users[cur]:--}" "$cols"
            frame+="$line${e}[K"$'\n'
            if [[ -n "$msg" ]]; then
                _dports_fit line " $msg" "$cols"
                frame+="$t_yellow$line$t_reset${e}[K"
            else
                _dports_fit line " ↑↓ move  Space toggle  u updates  a all  n none  Enter pull  q quit" "$cols"
                frame+="$t_dim$line$t_reset${e}[K"
            fi
            printf '%s' "${e}[H$frame${e}[J" >&3
        }

        while true; do
            _dports_tui_draw
            # Time out now and then to redraw after a terminal resize
            IFS= read -rsn1 -t 1 -u 3 key
            rc=$?
            if (( rc > 128 )); then continue    # timeout
            elif (( rc != 0 )); then exit 1     # the terminal went away
            fi
            msg=""
            if [[ "$key" == "$e" ]]; then
                rest=""
                if IFS= read -rsn1 -t 0.05 -u 3 c; then
                    rest="$c"
                    if [[ "$c" == "[" || "$c" == O ]]; then
                        while IFS= read -rsn1 -t 0.05 -u 3 c; do
                            rest+="$c"
                            [[ "$c" == [A-Za-z~] ]] && break
                        done
                    fi
                fi
                case "$rest" in
                    "")                     exit 1 ;;       # Esc on its own
                    "[A"|OA)                key=up ;;
                    "[B"|OB)                key=down ;;
                    "[5~")                  key=pgup ;;
                    "[6~")                  key=pgdn ;;
                    "[H"|OH|"[1~"|"[7~")    key=home ;;
                    "[F"|OF|"[4~"|"[8~")    key=end ;;
                    *)                      key=ignore ;;
                esac
            fi
            case "$key" in
                up|k)       (( cur > 0 )) && (( cur-- )) ;;
                down|j)     (( cur < n - 1 )) && (( cur++ )) ;;
                pgup)       (( cur -= page )); (( cur < 0 )) && cur=0 ;;
                pgdn)       (( cur += page )); (( cur > n - 1 )) && cur=$(( n - 1 )) ;;
                home|g)     cur=0 ;;
                end|G)      cur=$(( n - 1 )) ;;
                " "|x)      sel[cur]=$(( 1 - sel[cur] )) ;;
                u)          for (( i = 0; i < n; i++ )); do
                                if [[ "${st[i]}" == update ]]; then sel[i]=1; else sel[i]=0; fi
                            done ;;
                a)          for (( i = 0; i < n; i++ )); do sel[i]=1; done ;;
                n)          for (( i = 0; i < n; i++ )); do sel[i]=0; done ;;
                q|Q|$'\004') exit 1 ;;
                "")         # Enter
                            rest=""
                            for (( i = 0; i < n; i++ )); do (( sel[i] )) && rest+="$i"$'\n'; done
                            if [[ -z "$rest" ]]; then
                                msg="Nothing selected: Space selects an image, q quits"
                            else
                                printf '%s' "$rest"
                                exit 0
                            fi ;;
            esac
        done
    }

    # Print the status table (also used for --check and without a terminal)
    _dports_update_report() {
        local i w=5 numbered="${1:-false}" prefix col
        for (( i = 0; i < ${#images[@]}; i++ )); do (( ${#images[i]} > w )) && w=${#images[i]}; done
        (( w > 50 )) && w=50
        prefix=""; [[ "$numbered" == true ]] && prefix="     "
        printf "${C_BOLD}%s%-${w}s  %-8s %s${C_RESET}\n" "$prefix" "IMAGE" "STATUS" "CONTAINERS"
        for (( i = 0; i < ${#images[@]}; i++ )); do
            case "${st[i]}" in
                update)  col="$C_YELLOW" ;;
                current) col="$C_GREEN" ;;
                local)   col="$C_CYAN" ;;
                unknown) col="$C_RED" ;;
                *)       col="$C_DIM" ;;
            esac
            [[ "$numbered" == true ]] && prefix=$(printf '%3d) ' $(( i + 1 )))
            printf "%s%-${w}s  ${col}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
                "$prefix" "${images[i]}" "${st[i]}" "${users[i]}"
        done
    }

    # Check images, let the user pick, pull the picks, explain what is next.
    _dports_update() {
        local mode=interactive arg
        for arg in "$@"; do
            case "$arg" in
                --check)        mode=check ;;
                -y|--yes)       mode=yes ;;
                -c|--color)     C_RESET='\033[0m' C_BOLD='\033[1m' C_DIM='\033[2m'
                                C_CYAN='\033[36m' C_GREEN='\033[32m' C_YELLOW='\033[33m' C_RED='\033[31m' ;;
                -C|--no-color)  C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' ;;
                -h|--help)      _dports_update_usage; return 0 ;;
                *)
                    echo "Error: Unknown update option: $arg" >&2
                    echo "Run 'dports update --help' for usage information." >&2
                    return 1 ;;
            esac
        done

        if ! command -v docker &>/dev/null; then
            echo "Error: Docker is not installed or not in PATH" >&2; return 1
        fi
        local platform
        if ! platform=$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null) || [[ -z "$platform" ]]; then
            echo "Error: Cannot connect to Docker daemon." >&2; return 1
        fi
        # Docker reports the kernel's machine name; registries use GOARCH/variant
        case "$platform" in
            */x86_64)           platform="${platform%/*}/amd64" ;;
            */aarch64|*/arm64)  platform="${platform%/*}/arm64" ;;
            */armv7*)           platform="${platform%/*}/arm/v7" ;;
            */armv6*)           platform="${platform%/*}/arm/v6" ;;
            */armv5*)           platform="${platform%/*}/arm/v5" ;;
            */i[3-6]86)         platform="${platform%/*}/386" ;;
        esac

        # Running containers, by the reference each was created from:
        # `docker ps` shows a bare image ID once the tag has moved on.
        local container_ids
        container_ids=$(docker ps -q 2>/dev/null)
        local -a c_img=() c_name=() c_dir=() c_svc=()
        local a b c d
        if [[ -n "$container_ids" ]]; then
            # shellcheck disable=SC2086
            while IFS=$'\037' read -r a b c d; do
                [[ -n "$a" ]] || continue
                c_img+=("$a"); c_name+=("$b"); c_dir+=("$c"); c_svc+=("$d")
            done < <(docker inspect --format '{{.Config.Image}}{{"\t"}}{{slice .Name 1}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project.working_dir"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}' \
                $container_ids 2>/dev/null | tr '\t' '\037')
        fi
        if [[ ${#c_img[@]} -eq 0 ]]; then
            echo "No running containers found." >&2; return 0
        fi

        local -a images=() st=() detail=() users=()
        local -A by_img=()
        local i k
        mapfile -t images < <(printf '%s\n' "${c_img[@]}" | sort -u)
        for (( k = 0; k < ${#c_img[@]}; k++ )); do
            by_img["${c_img[k]}"]+="${by_img["${c_img[k]}"]:+, }${c_name[k]}"
        done
        local n=${#images[@]}
        for (( i = 0; i < n; i++ )); do users[i]="${by_img["${images[i]}"]}"; done

        # ── Check phase (parallel, at most 8 registry queries at a time) ─────
        local tmpdir
        tmpdir=$(mktemp -d) || return 1
        # The double subshell keeps an interactive shell from printing
        # job-control notices and from waiting on the workers.
        (
            (
                for (( i = 0; i < n; i++ )); do
                    while (( $(jobs -rp | wc -l) >= 8 )); do wait -n 2>/dev/null; done
                    {
                        _dports_check_image_update "${images[i]}" "$platform" > "$tmpdir/$i.tmp" 2>/dev/null
                        mv -f "$tmpdir/$i.tmp" "$tmpdir/$i"
                    } &
                done
                wait
                : > "$tmpdir/done"
            ) &
            echo $! > "$tmpdir/pid"
        )
        local pid f done_n
        pid=$(cat "$tmpdir/pid" 2>/dev/null)
        while [[ ! -e "$tmpdir/done" ]]; do
            if [[ -t 2 ]]; then
                done_n=0
                for f in "$tmpdir"/[0-9]*; do
                    [[ -e "$f" && "$f" != *.tmp ]] && (( done_n++ ))
                done
                printf '\r\033[K  Checking %d image(s) for updates... %d/%d' "$n" "$done_n" "$n" >&2
            fi
            [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && [[ ! -e "$tmpdir/done" ]] && break
            sleep 0.1
        done
        [[ -t 2 ]] && printf '\r\033[K' >&2

        local n_upd=0 n_unknown=0
        for (( i = 0; i < n; i++ )); do
            IFS=$'\t' read -r "st[i]" "detail[i]" 2>/dev/null < "$tmpdir/$i"
            if [[ -z "${st[i]}" ]]; then
                st[i]=unknown detail[i]="The check did not finish"
            fi
            [[ "${st[i]}" == update ]] && (( n_upd++ ))
            [[ "${st[i]}" == unknown ]] && (( n_unknown++ ))
        done
        rm -rf "$tmpdir"

        # ── Selection phase ──────────────────────────────────────────────────
        local -a chosen=()
        if [[ "$mode" == interactive && ! ( -t 0 && -t 1 ) ]]; then
            mode=check
            local not_tty=true
        fi

        case "$mode" in
            check)
                _dports_update_report
                echo
                printf '%d image(s) checked, %d with updates.\n' "$n" "$n_upd"
                [[ -n "${not_tty:-}" ]] && echo "Not a terminal: nothing was pulled (use --yes to pull every update)."
                return 0 ;;
            yes)
                for (( i = 0; i < n; i++ )); do [[ "${st[i]}" == update ]] && chosen+=("$i"); done
                _dports_update_report
                echo ;;
            interactive)
                if (( n_upd == 0 && n_unknown == 0 )); then
                    _dports_update_report
                    echo
                    echo "All images are up to date."
                    return 0
                fi
                local picks ret=2
                if [[ "${TERM:-dumb}" != dumb ]]; then
                    picks=$(_dports_update_tui); ret=$?
                fi
                if (( ret == 2 )); then
                    # No full-screen terminal: numbered prompt
                    _dports_update_report true
                    echo
                    local input="" num
                    read -rp "Numbers to pull (space-separated), 'u' for all updates, Enter to quit: " input
                    case "$input" in
                        u|U|a|A) for (( i = 0; i < n; i++ )); do [[ "${st[i]}" == update ]] && chosen+=("$i"); done ;;
                        *)
                            for num in $input; do
                                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= n )); then
                                    chosen+=("$(( num - 1 ))")
                                fi
                            done ;;
                    esac
                elif (( ret != 0 )); then
                    echo "Cancelled."; return 0
                else
                    mapfile -t chosen <<<"$picks"
                fi ;;
        esac

        if [[ ${#chosen[@]} -eq 0 ]]; then
            if [[ "$mode" == yes ]]; then echo "All images are up to date."; else echo "No images selected."; fi
            return 0
        fi

        # ── Pull phase ───────────────────────────────────────────────────────
        printf "${C_BOLD}Pulling %d image(s)${C_RESET}\n" "${#chosen[@]}"
        local n_updated=0 n_current=0 n_failed=0 output before after label image
        local -A updated=()
        for (( k = 0; k < ${#chosen[@]}; k++ )); do
            image="${images[${chosen[k]}]}"
            label="[$(( k + 1 ))/${#chosen[@]}] $image"
            [[ -t 1 ]] && printf "  ${C_CYAN}%s${C_RESET} ..." "$label"
            # Compare image IDs before/after instead of parsing pull output,
            # whose wording differs between image stores and Docker versions.
            before=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)
            if output=$(docker pull "$image" 2>&1); then
                after=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)
                [[ -t 1 ]] && printf '\r\033[K'
                if [[ "$before" != "$after" ]]; then
                    printf "  ${C_CYAN}%s${C_RESET}  ${C_GREEN}updated${C_RESET}\n" "$label"
                    updated["$image"]=1
                    (( n_updated++ ))
                else
                    printf "  ${C_CYAN}%s${C_RESET}  ${C_DIM}already up to date${C_RESET}\n" "$label"
                    (( n_current++ ))
                fi
            else
                [[ -t 1 ]] && printf '\r\033[K'
                printf "  ${C_CYAN}%s${C_RESET}  ${C_RED}failed${C_RESET}\n" "$label"
                echo "$output" | tail -3 | sed 's/^/      /'
                (( n_failed++ ))
            fi
        done

        # ── Summary ──────────────────────────────────────────────────────────
        echo
        printf "${C_BOLD}Updated %d · already current %d · failed %d${C_RESET}\n" \
            "$n_updated" "$n_current" "$n_failed"

        if (( n_updated > 0 )); then
            # Containers keep the old image until they are recreated
            local -A dir_svcs=() seen=()
            local -a standalone=() dirs=()
            for (( k = 0; k < ${#c_img[@]}; k++ )); do
                [[ -n "${updated["${c_img[k]}"]:-}" ]] || continue
                if [[ -n "${c_dir[k]}" && -n "${c_svc[k]}" ]]; then
                    [[ -n "${seen["${c_dir[k]}|${c_svc[k]}"]:-}" ]] && continue
                    seen["${c_dir[k]}|${c_svc[k]}"]=1
                    dir_svcs["${c_dir[k]}"]+=" ${c_svc[k]}"
                else
                    standalone+=("${c_name[k]}")
                fi
            done
            echo
            echo "Running containers keep the old image until they are recreated:"
            mapfile -t dirs < <(printf '%s\n' "${!dir_svcs[@]}" | sed '/^$/d' | sort)
            for d in "${dirs[@]}"; do
                printf "  ${C_CYAN}cd %q && docker compose up -d%s${C_RESET}\n" "$d" "${dir_svcs[$d]}"
            done
            for d in "${standalone[@]}"; do
                printf "  ${C_CYAN}%s${C_RESET} ${C_DIM}(not managed by Compose: recreate it with its original docker run options)${C_RESET}\n" "$d"
            done
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
            local hosts ports host port json quick found
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
                    found=$(awk -v quick="$quick" '
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
                    }' <<<"$json")
                    if [[ -n "$found" ]]; then
                        printf '%s\n' "$found"
                        return 0
                    fi
                    # The server answered without usable rules: try the config file
                    break 2
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
                read -r cf_id cf_mode cf_nets < <(docker inspect --format \
                    '{{.Id}} {{.HostConfig.NetworkMode}} {{range $net, $c := .NetworkSettings.Networks}}{{$net}},{{end}}' "$cf" 2>/dev/null)
                if [[ "$cf_mode" == container:* ]]; then
                    cf_mode="container:$(docker inspect --format '{{slice .Name 1}}' "${cf_mode#container:}" 2>/dev/null)"
                fi
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
                C_RED='\033[31m'
                shift
                ;;
            -C|--no-color)
                C_RESET=''
                C_BOLD=''
                C_DIM=''
                C_CYAN=''
                C_GREEN=''
                C_YELLOW=''
                C_RED=''
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
                shift
                _dports_update "$@"
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

    # Get container data (this also tells whether the daemon is reachable)
    local data
    if ! data=$(docker ps --format "{{.Ports}}\t{{.Names}}\t{{.Image}}" 2>/dev/null); then
        echo "Error: Cannot connect to Docker daemon." >&2
        echo "Is Docker running? Do you have permission to access it?" >&2
        return 1
    fi

    # With -q/-j, --tunnel prints only the tunnel routes (one kind of record)
    if [[ "$show_tunnel" == true && ( "$quiet" == true || "$json_output" == true ) ]]; then
        _dports_tunnel_section
        return
    fi

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
