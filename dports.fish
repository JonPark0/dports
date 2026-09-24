#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.2.3
# License: MIT
#
# Installation:
#   Copy to ~/.config/fish/functions/dports.fish
#   Completions: copy completions/dports.fish to ~/.config/fish/completions/
#

set -g DPORTS_VERSION "2.2.3"

# Path of this file: `dports update` re-sources it in helper fish processes,
# because fish cannot run functions in the background.
set -g __dports_source (realpath (status current-filename) 2>/dev/null)

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

    # Get container data
    set -l data (docker ps --format "{{.Ports}}\t{{.Names}}\t{{.Image}}" 2>/dev/null)

    # Stopped containers have an empty Ports column in `docker ps -a`,
    # so read their configured bindings from `docker inspect` instead.
    if test "$show_all" = true
        set -l stopped_ids (docker ps -aq --filter status=created --filter status=exited --filter status=dead 2>/dev/null)
        if test (count $stopped_ids) -gt 0
            set -a data (docker inspect --format \
                '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{if .HostPort}}{{.HostIp}}:{{.HostPort}}->{{$p}}, {{end}}{{end}}{{end}}{{"\t"}}{{slice .Name 1}}{{"\t"}}{{.Config.Image}}' \
                $stopped_ids 2>/dev/null)
        end
    end

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
# Compares the digests recorded when the image was pulled (RepoDigests)
# against the registry, which works with both the classic and the
# containerd image store.
# Usage: __dports_check_image_update IMAGE [OS/ARCH]
# Prints: update-available | up-to-date | pinned | ?
function __dports_check_image_update
    set -l image $argv[1]
    set -l platform linux/amd64
    set -q argv[2]; and set platform $argv[2]
    set -l os (string split -m 1 / -- $platform)[1]
    set -l arch (string split -m 1 / -- $platform)[2]

    # Digest-pinned references can never change by pulling
    if string match -q '*@sha256:*' -- $image
        echo pinned; return
    end

    set -l inspect (docker image inspect $image \
        --format '{{.Id}}{{range .RepoDigests}} {{.}}{{end}}' 2>/dev/null)
    if test $status -ne 0; or test -z "$inspect"
        echo "?"; return
    end
    set -l refs (string split ' ' -- "$inspect")
    set -l local_id $refs[1]
    set -e refs[1]
    set -l repo_digests
    for ref in $refs
        set -a repo_digests (string replace -r '.*@' '' -- $ref)
    end
    # Locally built images have no registry digest to compare against
    if test (count $repo_digests) -eq 0
        echo "?"; return
    end

    # Preferred: buildx reports the top-level (index) digest directly.
    # Parse its default output: older buildx releases ignore --format.
    set -l remote_digest ""
    if docker buildx version >/dev/null 2>&1
        set remote_digest (docker buildx imagetools inspect $image 2>/dev/null \
            | awk '$1 == "Digest:" { print $2; exit }')
    end
    if string match -q 'sha256:*' -- "$remote_digest"
        if contains -- $remote_digest $repo_digests
            echo up-to-date
        else
            echo update-available
        end
        return
    end

    # Fallback: `docker manifest inspect -v` yields the platform manifest
    # digest and its config digest (parsed with jq or python3).
    set -l manifest (env DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect -v $image 2>/dev/null)
    if test $status -ne 0; or test -z "$manifest"
        echo "?"; return
    end
    set -l fields ""
    if command -q jq
        set fields (printf '%s\n' $manifest | jq -r --arg os $os --arg arch $arch '
            (if type == "array" then "list" else "single" end) as $kind
            | [if type == "array" then .[] else . end
               | select($kind == "single"
                   or (.Descriptor.platform.os == $os
                       and .Descriptor.platform.architecture == $arch))][0]
            | [$kind, (.Descriptor.digest // ""),
               ((.SchemaV2Manifest // .OCIManifest).config.digest // "")]
            | join(" ")' 2>/dev/null)
    else if command -q python3
        set fields (printf '%s\n' $manifest | python3 -c '
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
' $os $arch 2>/dev/null)
    end

    # Pad so that missing fields expand to empty strings
    set -l parts (string split ' ' -- "$fields") "" "" ""
    set -l kind $parts[1]
    set -l plat_digest $parts[2]
    set -l config_digest $parts[3]
    if not string match -q 'sha256:*' -- "$plat_digest"
        echo "?"; return
    end

    if contains -- $plat_digest $repo_digests; or test "$local_id" = "$config_digest"
        echo up-to-date
    else if test "$kind" = single
        # A single manifest's digest is the top-level digest: a mismatch is real
        echo update-available
    else if test -n "$config_digest"; and not contains -- $local_id $repo_digests
        # Classic image store: the image ID is the config digest
        echo update-available
    else
        # containerd store with a multi-arch index: cannot tell without buildx
        echo "?"
    end
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
    set -l platform (docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null)
    if test $status -ne 0; or test -z "$platform"
        echo "Error: Cannot connect to Docker daemon." >&2; return 1
    end
    set platform (string replace -r 'x86_64$' amd64 -- $platform \
        | string replace -r 'aarch64$' arm64 \
        | string replace -r 'armv[0-9]*l$' arm)

    # Use the reference each container was created from: `docker ps`
    # shows a bare image ID once the tag has moved to a newer image.
    set -l images
    set -l container_ids (docker ps -q)
    if test (count $container_ids) -gt 0
        set images (docker inspect --format '{{.Config.Image}}' $container_ids | sort -u)
    end
    if test (count $images) -eq 0
        echo "No running containers found." >&2; return 0
    end

    # ── Check phase (parallel) ────────────────────────────────────────────────
    printf "%s%s%s\n\n" $c_bold "Checking for image updates..." $c_reset

    set -l tmpdir (mktemp -d)
    printf "  Querying %d image(s) in parallel..." (count $images)
    if test -r "$__dports_source"; and command -q fish
        # fish cannot background functions, so every check runs in its own
        # fish process. sh does the fan-out, which keeps an interactive
        # fish from printing job notices.
        env DPORTS_SOURCE=$__dports_source DPORTS_PLATFORM=$platform sh -c '
            dir=$1; shift; i=1
            for img in "$@"; do
                DPORTS_IMAGE=$img fish -c "source \"\$DPORTS_SOURCE\"; __dports_check_image_update \"\$DPORTS_IMAGE\" \"\$DPORTS_PLATFORM\"" > "$dir/$i" 2>/dev/null &
                i=$((i + 1))
            done
            wait' sh $tmpdir $images
    else
        set -l idx 1
        for image in $images
            __dports_check_image_update $image $platform > $tmpdir/$idx
            set idx (math $idx + 1)
        end
    end
    printf " done.\n\n"

    set -l status_list
    set -l idx 1
    for image in $images
        # The last line is the result (config.fish may print on startup)
        set -l st (tail -n 1 $tmpdir/$idx 2>/dev/null)
        test -z "$st"; and set st "?"
        set -a status_list $st
        switch $st
            case update-available
                printf "  %-45s %s[UPDATE AVAILABLE]%s\n" "$image" $c_yellow $c_reset
            case up-to-date
                printf "  %-45s %s[OK]%s\n" "$image" $c_green $c_reset
            case pinned
                printf "  %-45s %s[PINNED]%s\n" "$image" $c_dim $c_reset
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
            set -l label ""
            set -l state ""
            switch $status_list[$img_idx]
                case update-available
                    set label "[UPDATE AVAILABLE]"; set state ON
                case up-to-date
                    set label "[Up to date]";        set state OFF
                case pinned
                    set label "[Pinned digest]";     set state OFF
                case '*'
                    set label "[Status unknown]";    set state ON
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

        # whiptail prints "img1" "img2"; image references never contain
        # quotes or whitespace, so stripping the quotes is enough.
        set -l raw (cat "$tmpfile")
        rm -f "$tmpfile"
        for tok in (string split ' ' -- (string replace -a '"' '' -- "$raw"))
            test -n "$tok"; and set -a selected $tok
        end
    else
        # Plain-text fallback
        printf "%s%s%s\n" $c_bold "Available images:" $c_reset
        set -l idx 1
        for image in $images
            set -l slabel
            switch $status_list[$idx]
                case update-available; set slabel (printf "%s[UPDATE]%s" $c_yellow $c_reset)
                case up-to-date;       set slabel (printf "%s[OK]%s"     $c_green  $c_reset)
                case pinned;           set slabel (printf "%s[PINNED]%s" $c_dim    $c_reset)
                case '*';              set slabel (printf "%s[?]%s"      $c_dim    $c_reset)
            end
            printf "  %2d) %s  %s\n" $idx "$image" "$slabel"
            set idx (math $idx + 1)
        end
        echo
        set -l input ""
        read -l -P "Enter numbers (space-separated), 'a' for all with updates, 'q' to quit: " input

        switch "$input"
            case q Q ""
                echo "Cancelled."; return 0
            case a A
                set -l idx 1
                for image in $images
                    if not contains -- "$status_list[$idx]" up-to-date pinned
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
        # Compare image IDs before/after instead of parsing pull output,
        # whose wording differs between image stores and Docker versions.
        set -l before (docker image inspect --format '{{.Id}}' $image 2>/dev/null)
        set -l output (docker pull "$image" 2>&1)
        set -l exit_code $status
        if test $exit_code -eq 0
            set -l after (docker image inspect --format '{{.Id}}' $image 2>/dev/null)
            if test "$before" != "$after"
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
    if test $n_updated -gt 0
        printf "\n%sRunning containers keep the old image until they are recreated\n" $c_dim
        printf "(e.g. 'docker compose up -d' in the project directory).%s\n" $c_reset
    end
    test $n_failed -eq 0
end
