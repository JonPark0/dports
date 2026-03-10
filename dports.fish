#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.1.0
# License: MIT
#
# Installation:
#   Copy to ~/.config/fish/functions/dports.fish
#

set -g DPORTS_VERSION "2.1.2"

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

# Completions for fish
complete -c dports -f
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
