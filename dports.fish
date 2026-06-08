#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.2.2
# License: MIT
#
# Installation:
#   Copy to ~/.config/fish/functions/dports.fish
#

set -g DPORTS_VERSION "2.2.2"

function dports --description "Display Docker container port mappings"
    # Default options
    set -l verbose false
    set -l show_all false
    set -l filter_port ""
    set -l filter_name ""
    set -l filter_image ""
    set -l quiet false
    set -l json_output false
    set -l use_color true

    # Disable color if not a terminal
    if not isatty stdout
        set use_color false
    end

    # Parse arguments
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case -v --verbose
                set verbose true
            case -a --all
                set show_all true
            case -p --port
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Error: --port requires a port number" >&2
                    return 1
                end
                set filter_port $argv[$i]
            case -n --name
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Error: --name requires a name pattern" >&2
                    return 1
                end
                set filter_name $argv[$i]
            case -i --image
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Error: --image requires an image pattern" >&2
                    return 1
                end
                set filter_image $argv[$i]
            case -c --color
                set use_color true
            case -C --no-color
                set use_color false
            case -q --quiet
                set quiet true
            case -j --json
                set json_output true
            case -h --help
                __dports_usage
                return 0
            case -V --version
                echo "dports version $DPORTS_VERSION"
                return 0
            case update
                __dports_update
                return $status
            case '-*'
                echo "Error: Unknown option: $argv[$i]" >&2
                echo "Run 'dports --help' for usage information." >&2
                return 1
            case '*'
                echo "Error: Unexpected argument: $argv[$i]" >&2
                echo "Run 'dports --help' for usage information." >&2
                return 1
        end
        set i (math $i + 1)
    end

    # Check if Docker is available
    if not command -q docker
        echo "Error: Docker is not installed or not in PATH" >&2
        return 1
    end

    if not docker info >/dev/null 2>&1
        echo "Error: Cannot connect to Docker daemon." >&2
        echo "Is Docker running? Do you have permission to access it?" >&2
        return 1
    end

    # Build docker ps command
    set -l docker_opts
    if test "$show_all" = true
        set docker_opts -a
    end

    # Get container data
    set -l data (docker ps $docker_opts --format "{{.Ports}}\t{{.Names}}\t{{.Image}}" 2>/dev/null)

    if test -z "$data"
        if test "$json_output" = true
            echo "[]"
        else
            echo "No containers found." >&2
        end
        return 0
    end

    # Process and filter data
    set -l results (printf '%s\n' $data | awk -F"\t" \
        -v verbose="$verbose" \
        -v filter_port="$filter_port" \
        -v filter_name="$filter_name" \
        -v filter_image="$filter_image" \
        -v quiet="$quiet" \
        -v json="$json_output" \
    '{
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
                
                # Extract host port (handle IPv4/IPv6)
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
    }' | sort -t\t -k1 -V | uniq)

    # Handle empty results
    if test -z "$results"
        if test "$json_output" = true
            echo "[]"
        else if test -n "$filter_port" -o -n "$filter_name" -o -n "$filter_image"
            echo "No containers match the specified filters." >&2
        else
            echo "No containers with exposed ports found." >&2
        end
        return 0
    end

    # Set up colors
    set -l c_reset ""
    set -l c_bold ""
    set -l c_dim ""
    set -l c_cyan ""
    set -l c_green ""
    set -l c_yellow ""

    if test "$use_color" = true
        set c_reset (set_color normal)
        set c_bold (set_color --bold)
        set c_dim (set_color --dim)
        set c_cyan (set_color cyan)
        set c_green (set_color green)
        set c_yellow (set_color yellow)
    end

    # Output formatting
    if test "$quiet" = true
        # Quiet mode: just port numbers
        printf '%s\n' $results
    else if test "$json_output" = true
        # JSON output
        echo "["
        set -l first true
        for line in $results
            set -l fields (string split \t $line)
            if test "$first" = true
                set first false
            else
                echo ","
            end
            printf '  {"port": "%s", "name": "%s", "internal": "%s", "image": "%s"}' \
                $fields[1] $fields[2] $fields[3] $fields[4]
        end
        echo ""
        echo "]"
    else if test "$verbose" = true
        # Verbose mode with internal port
        printf "%s%-8s  %-28s  %-15s  %s%s\n" \
            "$c_bold" "PORT" "NAME" "INTERNAL" "IMAGE" "$c_reset"
        printf "%s%-8s  %-28s  %-15s  %s%s\n" \
            "$c_dim" "────────" "────────────────────────────" "───────────────" "────────────────────────" "$c_reset"
        for line in $results
            set -l fields (string split \t $line)
            printf "%s%-8s%s  %s%-28s%s  %s%-15s%s  %s\n" \
                "$c_green" $fields[1] "$c_reset" \
                "$c_cyan" $fields[2] "$c_reset" \
                "$c_yellow" $fields[3] "$c_reset" \
                $fields[4]
        end
    else
        # Standard mode
        printf "%s%-8s  %-28s  %s%s\n" \
            "$c_bold" "PORT" "NAME" "IMAGE" "$c_reset"
        printf "%s%-8s  %-28s  %s%s\n" \
            "$c_dim" "────────" "────────────────────────────" "────────────────────────" "$c_reset"
        for line in $results
            set -l fields (string split \t $line)
            printf "%s%-8s%s  %s%-28s%s  %s\n" \
                "$c_green" $fields[1] "$c_reset" \
                "$c_cyan" $fields[2] "$c_reset" \
                $fields[3]
        end
    end
end

# Help function
function __dports_usage
    echo "dports - Display Docker container port mappings

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
    dports -n nginx             Filter by container name containing \"nginx\"
    dports -i postgres          Filter by image name containing \"postgres\"
    dports -n web -p 80         Combine filters (AND logic)
    dports -q                   List only port numbers
    dports -j                   Output as JSON array

OUTPUT COLUMNS:
    PORT        Host port (external)
    NAME        Container name
    INTERNAL    Internal port with protocol (verbose mode only)
    IMAGE       Docker image name"
end

# Check whether a single image has an available update.
# Compares local config digest to remote manifest.
# Prints: update-available | up-to-date | ?
function __dports_check_image_update
    set -l image $argv[1]

    set -l local_id (docker image inspect "$image" --format '{{.Id}}' 2>/dev/null)
    if test -z "$local_id"
        echo "?"; return
    end

    set -l arch (docker info --format '{{.Architecture}}' 2>/dev/null | sed 's/x86_64/amd64/g;s/aarch64/arm64/g')
    test -z "$arch"; and set arch "amd64"

    set -l manifest (DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$image" 2>/dev/null)
    if test -z "$manifest"
        echo "?"; return
    end

    set -l remote_config_digest ""

    if echo "$manifest" | grep -q '"manifests"'
        # Multi-arch manifest list
        set -l plat_digest ""
        if command -q jq
            set plat_digest (echo "$manifest" | jq -r --arg a "$arch" \
                '.manifests[] | select(.platform.architecture == $a) | .digest' 2>/dev/null | head -1)
        else if command -q python3
            set plat_digest (echo "$manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('manifests', []):
    if m.get('platform', {}).get('architecture') == sys.argv[1]:
        print(m['digest']); break
" "$arch" 2>/dev/null)
        end

        if test -z "$plat_digest"; or test "$plat_digest" = "null"
            echo "?"; return
        end

        set -l image_base (echo "$image" | sed 's/:[^:/]*$//')
        set -l plat_manifest (DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect \
            "$image_base@$plat_digest" 2>/dev/null)
        if test -z "$plat_manifest"
            echo "?"; return
        end

        if command -q jq
            set remote_config_digest (echo "$plat_manifest" | jq -r '.config.digest // ""' 2>/dev/null)
        else if command -q python3
            set remote_config_digest (echo "$plat_manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('config', {}).get('digest', ''))
" 2>/dev/null)
        else
            set remote_config_digest (echo "$plat_manifest" | awk \
                '/"config"/{c=1} c&&/"digest"/{match($0,/"digest": *"(sha256:[^"]+)"/,a);if(a[1]){print a[1];exit}}')
        end
    else
        # Single-arch manifest
        if command -q jq
            set remote_config_digest (echo "$manifest" | jq -r '.config.digest // ""' 2>/dev/null)
        else if command -q python3
            set remote_config_digest (echo "$manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('config', {}).get('digest', ''))
" 2>/dev/null)
        else
            set remote_config_digest (echo "$manifest" | awk \
                '/"config"/{c=1} c&&/"digest"/{match($0,/"digest": *"(sha256:[^"]+)"/,a);if(a[1]){print a[1];exit}}')
        end
    end

    if test -z "$remote_config_digest"; or test "$remote_config_digest" = "null"
        echo "?"; return
    end
    if test "$local_id" = "$remote_config_digest"
        echo "up-to-date"; return
    end
    echo "update-available"
end

# Interactive update TUI: check images, present checklist, pull selections.
function __dports_update
    set -l c_reset ""
    set -l c_bold ""
    set -l c_dim ""
    set -l c_cyan ""
    set -l c_green ""
    set -l c_yellow ""
    set -l c_red ""
    if isatty stdout
        set c_reset (set_color normal)
        set c_bold (set_color --bold)
        set c_dim (set_color --dim)
        set c_cyan (set_color cyan)
        set c_green (set_color green)
        set c_yellow (set_color yellow)
        set c_red (set_color red)
    end

    if not command -q docker
        echo "Error: Docker is not installed or not in PATH" >&2; return 1
    end
    if not docker info >/dev/null 2>&1
        echo "Error: Cannot connect to Docker daemon." >&2; return 1
    end

    set -l images (docker ps --format '{{.Image}}' | sort -u)
    if test (count $images) -eq 0
        echo "No running containers found." >&2; return 0
    end

    # ── Check phase (parallel) ────────────────────────────────────────────────
    printf "%s%s%s\n\n" $c_bold "Checking for image updates..." $c_reset

    set -l tmpdir (mktemp -d)
    set -l idx 1
    for image in $images
        begin
            set -l st (__dports_check_image_update $image)
            echo $st > $tmpdir/$idx
        end &
        set idx (math $idx + 1)
    end

    printf "  Querying %d image(s) in parallel..." (count $images)
    wait
    printf " done.\n\n"

    set -l status_list
    set idx 1
    for image in $images
        set -l st (cat $tmpdir/$idx 2>/dev/null; or echo "?")
        set -a status_list $st
        switch $st
            case update-available
                printf "  %-45s %s[UPDATE AVAILABLE]%s\n" "$image" $c_yellow $c_reset
            case up-to-date
                printf "  %-45s %s[OK]%s\n" "$image" $c_green $c_reset
            case '*'
                printf "  %-45s %s[?]%s\n" "$image" $c_dim $c_reset
        end
        set idx (math $idx + 1)
    end
    rm -rf $tmpdir
    echo

    # ── Selection phase ──────────────────────────────────────────────────────
    set -l selected

    # Detect TUI tool
    set -l dialog_tool ""
    if command -q whiptail
        set dialog_tool whiptail
    else if command -q dialog
        set dialog_tool dialog
    end

    if test -n "$dialog_tool"; and isatty stdin; and isatty stdout
        set -l items
        set -l img_idx 1
        for image in $images
            set -l st $status_list[$img_idx]
            set -l label state
            switch $st
                case update-available
                    set label "[UPDATE AVAILABLE]"; set state ON
                case up-to-date
                    set label "[Up to date]";        set state OFF
                case '*'
                    set label "[Status unknown]";   set state ON
            end
            set -a items "$image" "$label" "$state"
            set img_idx (math $img_idx + 1)
        end

        set -l num (count $images)
        set -l height (math $num + 9)
        test $height -lt 14; and set height 14
        test $height -gt 30; and set height 30

        set -l tmpfile (mktemp)
        $dialog_tool \
            --title "dports update" \
            --checklist "Select images to pull:\n(SPACE=toggle  ENTER=confirm  ESC=cancel)" \
            $height 72 $num \
            $items \
            2>"$tmpfile"
        set -l ret $status

        if test $ret -ne 0
            rm -f "$tmpfile"; echo "Cancelled."; return 0
        end

        set -l raw (cat "$tmpfile")
        rm -f "$tmpfile"
        # Parse quoted tokens from whiptail output
        for tok in (string split ' ' -- $raw)
            set -a selected (string trim --chars='"' -- $tok)
        end
    else
        # Plain-text fallback
        printf "%s%s%s\n" $c_bold "Available images:" $c_reset
        set -l idx 1
        for image in $images
            set -l st $status_list[$idx]
            set -l slabel
            switch $st
                case update-available; set slabel (printf "%s[UPDATE]%s" $c_yellow $c_reset)
                case up-to-date;       set slabel (printf "%s[OK]%s"     $c_green  $c_reset)
                case '*';              set slabel (printf "%s[?]%s"      $c_dim    $c_reset)
            end
            printf "  %2d) %s  %s\n" $idx "$image" "$slabel"
            set idx (math $idx + 1)
        end
        echo
        printf "Enter numbers (space-separated), 'a' for all with updates, 'q' to quit: "
        read -l input

        switch $input
            case q Q ""
                echo "Cancelled."; return 0
            case a A
                set -l idx 1
                for image in $images
                    if test "$status_list[$idx]" != "up-to-date"
                        set -a selected "$image"
                    end
                    set idx (math $idx + 1)
                end
            case '*'
                for num in (string split ' ' -- $input)
                    if string match -qr '^\d+$' -- $num
                        if test $num -ge 1; and test $num -le (count $images)
                            set -a selected $images[$num]
                        end
                    end
                end
        end
    end

    if test (count $selected) -eq 0
        echo "No images selected."; return 0
    end

    # ── Pull phase ───────────────────────────────────────────────────────────
    printf "\n%sPulling %d image(s)...%s\n\n" $c_bold (count $selected) $c_reset
    set -l n_updated 0
    set -l n_current 0
    set -l n_failed 0

    for image in $selected
        printf "%s▸ %s%s\n" $c_cyan "$image" $c_reset
        set -l output (docker pull "$image" 2>&1)
        set -l exit_code $status
        if test $exit_code -eq 0
            if printf '%s\n' $output | grep -q "Downloaded newer image\|Pull complete"
                printf "  %s✔ Updated%s\n" $c_green $c_reset
                set n_updated (math $n_updated + 1)
            else
                printf "  %s✔ Already up to date%s\n" $c_green $c_reset
                set n_current (math $n_current + 1)
            end
        else
            printf "  %s✗ Failed%s\n" $c_red $c_reset
            printf '%s\n' $output | tail -3 | sed 's/^/    /'
            set n_failed (math $n_failed + 1)
        end
        echo
    end

    # ── Summary ──────────────────────────────────────────────────────────────
    printf "%s─────────────────────%s\n" $c_bold $c_reset
    test $n_updated -gt 0; and printf "  %s✔ Updated:          %d%s\n" $c_green $n_updated $c_reset
    test $n_current -gt 0; and printf "  %s  Already current:   %d%s\n" $c_dim  $n_current $c_reset
    test $n_failed  -gt 0; and printf "  %s✗ Failed:           %d%s\n" $c_red  $n_failed  $c_reset
end

# Completions for fish
complete -c dports -f
complete -c dports -n "__fish_use_subcommand" -a update -d "Check for image updates (TUI)"
complete -c dports -s v -l verbose -d "Show detailed port mapping"
complete -c dports -s a -l all -d "Include stopped containers"
complete -c dports -s p -l port -d "Filter by port number" -x
complete -c dports -s n -l name -d "Filter by container name" -x
complete -c dports -s i -l image -d "Filter by image name" -x
complete -c dports -s c -l color -d "Force color output"
complete -c dports -s C -l no-color -d "Disable color output"
complete -c dports -s q -l quiet -d "Only show port numbers"
complete -c dports -s j -l json -d "Output in JSON format"
complete -c dports -s h -l help -d "Show help message"
complete -c dports -s V -l version -d "Show version"
