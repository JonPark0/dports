#!/usr/bin/env bash
#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.1.3
# License: MIT
#
# Installation:
#   Bash: Copy to ~/.bash_functions/dports and source from ~/.bashrc
#   Or:   Source this file directly in ~/.bashrc
#   Apt:  sudo apt install dports  (via Forgejo package registry)
#

DPORTS_VERSION="2.2.0"

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
    # Compares the local image config digest against the remote manifest.
    # Prints: update-available | up-to-date | ?
    _dports_check_image_update() {
        local image="$1"

        local local_id
        local_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null) || { echo "?"; return; }
        [[ -z "$local_id" ]] && { echo "?"; return; }

        local arch
        arch=$(docker info --format '{{.Architecture}}' 2>/dev/null | sed 's/x86_64/amd64/g;s/aarch64/arm64/g')
        [[ -z "$arch" ]] && arch="amd64"

        local manifest
        manifest=$(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$image" 2>/dev/null) || { echo "?"; return; }
        [[ -z "$manifest" ]] && { echo "?"; return; }

        local remote_config_digest=""

        if echo "$manifest" | grep -q '"manifests"'; then
            # Multi-arch manifest list — locate the platform-specific manifest first
            local plat_digest=""
            if command -v jq &>/dev/null; then
                plat_digest=$(echo "$manifest" | jq -r --arg a "$arch" \
                    '.manifests[] | select(.platform.architecture == $a) | .digest' \
                    2>/dev/null | head -1)
            elif command -v python3 &>/dev/null; then
                plat_digest=$(echo "$manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('manifests', []):
    if m.get('platform', {}).get('architecture') == '${arch}':
        print(m['digest']); break
" 2>/dev/null)
            fi
            [[ -z "$plat_digest" || "$plat_digest" == "null" ]] && { echo "?"; return; }

            # Strip tag to build the digest reference (handles registry:port/image:tag)
            local image_base
            image_base=$(echo "$image" | sed 's/:[^:/]*$//')
            local plat_manifest
            plat_manifest=$(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect \
                "${image_base}@${plat_digest}" 2>/dev/null) || { echo "?"; return; }

            if command -v jq &>/dev/null; then
                remote_config_digest=$(echo "$plat_manifest" | jq -r '.config.digest // ""' 2>/dev/null)
            elif command -v python3 &>/dev/null; then
                remote_config_digest=$(echo "$plat_manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('config', {}).get('digest', ''))
" 2>/dev/null)
            else
                remote_config_digest=$(echo "$plat_manifest" | awk \
                    '/"config"/{c=1} c&&/"digest"/{match($0,/"digest": *"(sha256:[^"]+)"/,a);if(a[1]){print a[1];exit}}')
            fi
        else
            # Single-arch manifest
            if command -v jq &>/dev/null; then
                remote_config_digest=$(echo "$manifest" | jq -r '.config.digest // ""' 2>/dev/null)
            elif command -v python3 &>/dev/null; then
                remote_config_digest=$(echo "$manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('config', {}).get('digest', ''))
" 2>/dev/null)
            else
                remote_config_digest=$(echo "$manifest" | awk \
                    '/"config"/{c=1} c&&/"digest"/{match($0,/"digest": *"(sha256:[^"]+)"/,a);if(a[1]){print a[1];exit}}')
            fi
        fi

        [[ -z "$remote_config_digest" || "$remote_config_digest" == "null" ]] && { echo "?"; return; }
        [[ "$local_id" == "$remote_config_digest" ]] && { echo "up-to-date"; return; }
        echo "update-available"
    }

    # Interactive update TUI: check images, present checklist, pull selections.
    _dports_update() {
        local UC_RESET UC_BOLD UC_DIM UC_CYAN UC_GREEN UC_YELLOW UC_RED
        if [[ -t 1 ]]; then
            UC_RESET='\033[0m'; UC_BOLD='\033[1m'; UC_DIM='\033[2m'
            UC_CYAN='\033[36m'; UC_GREEN='\033[32m'; UC_YELLOW='\033[33m'; UC_RED='\033[31m'
        fi

        if ! command -v docker &>/dev/null; then
            echo "Error: Docker is not installed or not in PATH" >&2; return 1
        fi
        if ! docker info &>/dev/null 2>&1; then
            echo "Error: Cannot connect to Docker daemon." >&2; return 1
        fi

        local images=()
        mapfile -t images < <(docker ps --format '{{.Image}}' | sort -u)
        if [[ ${#images[@]} -eq 0 ]]; then
            echo "No running containers found." >&2; return 0
        fi

        # ── Check phase ──────────────────────────────────────────────────────
        printf "${UC_BOLD}Checking for image updates...${UC_RESET}\n\n"
        declare -A img_status
        for image in "${images[@]}"; do
            printf "  Checking %-45s" "${image}..."
            local st
            st=$(_dports_check_image_update "$image")
            img_status["$image"]="$st"
            case "$st" in
                update-available) printf "${UC_YELLOW}[UPDATE AVAILABLE]${UC_RESET}\n" ;;
                up-to-date)       printf "${UC_GREEN}[OK]${UC_RESET}\n" ;;
                *)                printf "${UC_DIM}[?]${UC_RESET}\n" ;;
            esac
        done
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
            trap "rm -f '$tmpfile'" EXIT INT TERM HUP

            "$dialog_tool" \
                --title "dports update" \
                --checklist "Select images to pull:\n(SPACE=toggle  ENTER=confirm  ESC=cancel)" \
                "$height" 72 "$num" \
                "${items[@]}" \
                2>"$tmpfile"

            local ret=$?
            trap - EXIT INT TERM HUP
            if [[ $ret -ne 0 ]]; then
                rm -f "$tmpfile"; echo "Cancelled."; return 0
            fi

            local raw
            raw=$(cat "$tmpfile"); rm -f "$tmpfile"
            eval "selected=($raw)"
        else
            # Plain-text fallback
            printf "${UC_BOLD}Available images:${UC_RESET}\n"
            local idx=1
            for image in "${images[@]}"; do
                local slabel
                case "${img_status[$image]}" in
                    update-available) slabel="${UC_YELLOW}[UPDATE]${UC_RESET}" ;;
                    up-to-date)       slabel="${UC_GREEN}[OK]${UC_RESET}" ;;
                    *)                slabel="${UC_DIM}[?]${UC_RESET}" ;;
                esac
                printf "  %2d) %s  %b\n" "$idx" "$image" "$slabel"
                (( idx++ ))
            done
            echo
            printf "Enter numbers (space-separated), 'a' for all with updates, 'q' to quit: "
            read -r input

            case "$input" in
                q|Q|"") echo "Cancelled."; return 0 ;;
                a|A)
                    for image in "${images[@]}"; do
                        [[ "${img_status[$image]}" != "up-to-date" ]] && selected+=("$image")
                    done
                    ;;
                *)
                    for num in $input; do
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
            local output exit_code
            output=$(docker pull "$image" 2>&1)
            exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                if echo "$output" | grep -q "Downloaded newer image\|Pull complete"; then
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

    if ! docker info &>/dev/null 2>&1; then
        echo "Error: Cannot connect to Docker daemon." >&2
        echo "Is Docker running? Do you have permission to access it?" >&2
        return 1
    fi

    # Build docker ps options
    local docker_opts=""
    if [[ "$show_all" == true ]]; then
        docker_opts="-a"
    fi

    # Get container data
    local data
    data=$(docker ps $docker_opts --format "{{.Ports}}\t{{.Names}}\t{{.Image}}" 2>/dev/null)

    if [[ -z "$data" ]]; then
        if [[ "$json_output" == true ]]; then
            echo "[]"
        else
            echo "No containers found." >&2
        fi
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
}

# If script is executed directly (not sourced), run dports with arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    dports "$@"
fi
