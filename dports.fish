#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.3.0
# License: MIT
#
# Installation:
#   Copy to ~/.config/fish/functions/dports.fish
#   Completions: copy completions/dports.fish to ~/.config/fish/completions/
#

set -g DPORTS_VERSION "2.3.0"

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
    set -l show_tunnel false
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
            case -t --tunnel
                set show_tunnel true
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

    # With -q/-j, --tunnel prints only the tunnel routes (one kind of record)
    if test "$show_tunnel" = true; and test "$quiet" = true -o "$json_output" = true
        __dports_tunnel_section "$filter_port" "$filter_name" "$filter_image" $quiet $json_output $verbose $use_color
        return
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
        test "$show_tunnel" = true; and __dports_tunnel_section "$filter_port" \
            "$filter_name" "$filter_image" $quiet $json_output $verbose $use_color
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
        test "$show_tunnel" = true; and __dports_tunnel_section "$filter_port" \
            "$filter_name" "$filter_image" $quiet $json_output $verbose $use_color
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

    if test "$show_tunnel" = true
        echo
        __dports_tunnel_section "$filter_port" "$filter_name" "$filter_image" $quiet $json_output $verbose $use_color
    end
end

# ── Cloudflare Tunnel helpers ─────────────────────────────────────────────────
# The awk programs are shared verbatim with dports.bash (they avoid "\\",
# which fish single quotes would collapse).

# Fetch a URL to stdout with short timeouts (curl or wget)
function __dports_http_get
    if command -q curl
        curl -fsS --connect-timeout 1 --max-time 3 $argv[1] 2>/dev/null
    else if command -q wget
        wget -qO- -T 3 -t 1 $argv[1] 2>/dev/null
    else
        return 1
    end
end

# Print "hostname<TAB>path<TAB>service" for every ingress rule of a
# cloudflared container.
#   1. The metrics server's /config endpoint (works for locally and
#      remotely managed tunnels); only when DIRECT=true, i.e. the host
#      can reach container IPs (native Linux Docker).
#   2. The config file inside the container, read with `docker cp`.
#   3. A --url / TUNNEL_URL origin (quick tunnels, legacy mode).
# Usage: __dports_tunnel_ingress CONTAINER DIRECT
# Returns 1 if no rules could be read.
function __dports_tunnel_ingress
    set -l cf $argv[1]
    set -l direct $argv[2]
    set -l cf_args (docker inspect --format '{{range .Args}}{{.}}{{"\n"}}{{end}}' $cf 2>/dev/null)
    set -l cf_env (docker inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' $cf 2>/dev/null)
    set -l metrics ""
    set -l config ""
    set -l url ""
    set -l want ""
    for a in $cf_args
        switch "$want"
            case metrics
                set metrics $a
            case config
                set config $a
            case url
                set url $a
        end
        set want ""
        switch $a
            case '--metrics=*'
                set metrics (string replace -- '--metrics=' '' $a)
            case --metrics
                set want metrics
            case '--config=*'
                set config (string replace -- '--config=' '' $a)
            case --config
                set want config
            case '--url=*'
                set url (string replace -- '--url=' '' $a)
            case --url
                set want url
        end
    end
    set -l m (string match -r '^TUNNEL_METRICS=(.*)' -- $cf_env)
    test -z "$metrics"; and set -q m[2]; and set metrics $m[2]
    set m (string match -r '^TUNNEL_URL=(.*)' -- $cf_env)
    test -z "$url"; and set -q m[2]; and set url $m[2]
    set -l netmode (docker inspect --format '{{.HostConfig.NetworkMode}}' $cf 2>/dev/null)

    # 1. Metrics server
    if test "$direct" = true
        set -l hosts
        if test "$netmode" = host
            set hosts 127.0.0.1
        else
            set hosts (string split ' ' -- (docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $cf 2>/dev/null))
            # A loopback-only metrics address is unreachable from the host
            string match -qr '^(localhost|127\..*|\[::1\]):' -- "$metrics"; and set hosts
        end
        set -l ports 20241 20242 20243 20244 20245
        test -n "$metrics"; and set ports (string replace -r '.*:' '' -- $metrics)
        for host in $hosts
            test -n "$host"; or continue
            for port in $ports
                set -l json (__dports_http_get "http://$host:$port/config" | string collect)
                string match -q '{"version"*' -- "$json"; or continue
                set -l quick ""
                if test -n "$url"
                    set quick (__dports_http_get "http://$host:$port/quicktunnel" \
                        | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p')
                end
                printf '%s\n' $json | awk -v quick="$quick" '
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
                }'
                return 0
            end
        end
    end

    # 2. Config file inside the container (docker cp works on distroless)
    set -l paths
    if test -n "$config"
        if not string match -q '/*' -- $config
            set -l workdir (docker inspect --format '{{.Config.WorkingDir}}' $cf 2>/dev/null)
            test -z "$workdir"; and set workdir /
            set config "$workdir/$config"
        end
        set paths $config
    else
        set paths /etc/cloudflared/config.yml /etc/cloudflared/config.yaml \
            /home/nonroot/.cloudflared/config.yml /home/nonroot/.cloudflared/config.yaml \
            /root/.cloudflared/config.yml /root/.cloudflared/config.yaml
    end
    set -l yaml ""
    for p in $paths
        set yaml (docker cp "$cf:$p" - 2>/dev/null | tar -xOf - 2>/dev/null | string collect)
        test -n "$yaml"; and break
    end
    set -l rules
    if test -n "$yaml"
        set rules (printf '%s\n' $yaml | awk '
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
        }')
    end
    # 3. --url origin (quick tunnel or legacy flag-only setup)
    if test (count $rules) -eq 0; and test -n "$url"
        set rules (printf '\t\t%s' $url)
    end
    test (count $rules) -gt 0; or return 1
    printf '%s\n' $rules
end

# Print the Cloudflare Tunnel routes table (or JSON / hostnames).
# Each ingress rule is matched to the container its service points at,
# by container name, compose service, network alias, hostname or IP on
# a network shared with cloudflared.
# Usage: __dports_tunnel_section PORT NAME IMAGE QUIET JSON VERBOSE COLOR
function __dports_tunnel_section
    set -l filter_port $argv[1]
    set -l filter_name $argv[2]
    set -l filter_image $argv[3]
    set -l quiet $argv[4]
    set -l json_output $argv[5]
    set -l verbose $argv[6]
    set -l use_color $argv[7]

    set -l cfs (docker ps --no-trunc --format '{{.Names}}\t{{.Image}}\t{{.Command}}' 2>/dev/null \
        | awk -F'\t' 'tolower($2) ~ /cloudflared/ || $3 ~ /cloudflared/ { print $1 }')

    # Can the host reach container IPs? Not on Docker Desktop, rootless
    # Docker or a remote daemon.
    set -l direct false
    if test (uname -s) = Linux
        set -l endpoint "$DOCKER_HOST"
        test -z "$endpoint"; and set endpoint (docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
        set -l info (docker info --format '{{.OperatingSystem}} {{.SecurityOptions}}' 2>/dev/null)
        if begin; test -z "$endpoint"; or string match -q 'unix://*' -- "$endpoint"; end
            and not string match -q '*Docker Desktop*' -- "$info"
            and not string match -q '*rootless*' -- "$info"
            set direct true
        end
    end

    set -l stream
    set -l ids (docker ps -q)
    if test (count $cfs) -gt 0; and test (count $ids) -gt 0
        # Identity of every running container (I), containers sharing
        # another container's network namespace (S), published ports (P)
        set -a stream (docker inspect --format '{{$n := slice .Name 1}}{{$i := .Config.Image}}{{if eq (printf "%.10s" .HostConfig.NetworkMode) "container:"}}S{{"\t"}}{{.HostConfig.NetworkMode}}{{"\t"}}{{$n}}{{"\t"}}{{$i}}{{"\n"}}{{end}}{{$h := .Config.Hostname}}{{$s := index .Config.Labels "com.docker.compose.service"}}{{range $net, $c := .NetworkSettings.Networks}}I{{"\t"}}{{$n}}{{"\t"}}{{$i}}{{"\t"}}{{$net}}{{"\t"}}{{$c.IPAddress}}{{"\t"}}{{$n}} {{$h}} {{$s}} {{join $c.Aliases " "}}{{"\n"}}{{end}}' $ids 2>/dev/null)
        set -a stream (docker ps --format '{{.Ports}}\t{{.Names}}\t{{.Image}}' | awk -F'\t' '{
            n = split($1, ports, ", ")
            for (i = 1; i <= n; i++) if (ports[i] ~ /->/) {
                split(ports[i], m, "->"); hp = m[1]
                gsub(/^\[?[0-9a-fA-F.:]*\]?:/, "", hp)
                printf "P\t%s\t%s\t%s\n", hp, $2, $3
            }
        }')
        for cf in $cfs
            set -l rules (__dports_tunnel_ingress $cf $direct)
            if test $status -ne 0
                echo "Note: cannot read the ingress rules of '$cf'" \
                    "(no config file in the container, and its metrics server is not reachable from this host)." >&2
                continue
            end
            set -l cf_id (docker inspect --format '{{.Id}}' $cf)
            set -l cf_mode (docker inspect --format '{{.HostConfig.NetworkMode}}' $cf)
            if string match -q 'container:*' -- $cf_mode
                set cf_mode "container:"(docker inspect --format '{{slice .Name 1}}' (string replace -- 'container:' '' $cf_mode) 2>/dev/null)
            end
            set -l cf_nets (docker inspect --format '{{range $net, $c := .NetworkSettings.Networks}}{{$net}},{{end}}' $cf)
            set -a stream (printf '%s\n' $rules | awk -F'\t' -v cf=$cf -v id=$cf_id -v mode=$cf_mode -v nets="$cf_nets" \
                '{ printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cf, id, mode, nets, $1, $2, $3 }')
        end
    end

    set -l results (printf '%s\n' $stream | awk -F'\t' \
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
        }' | sort -t\t -k1,1 -k2,2 | uniq)

    if test (count $results) -eq 0
        if test "$json_output" = true
            echo "[]"
        else if test (count $cfs) -eq 0
            echo "No running cloudflared containers found." >&2
        else if test -n "$filter_port" -o -n "$filter_name" -o -n "$filter_image"
            echo "No tunnel routes match the specified filters." >&2
        else
            echo "No Cloudflare Tunnel routes found." >&2
        end
        return 0
    end

    if test "$quiet" = true
        printf '%s\n' $results | cut -f1 | uniq
    else if test "$json_output" = true
        printf '%s\n' $results | awk -F'\t' '
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
        END { if (NR) print prev; print "]" }'
    else
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
        if test "$verbose" = true
            printf "%s%-32s  %-24s  %-30s  %-16s  %s%s\n" \
                "$c_bold" "HOSTNAME" "NAME" "SERVICE" "TUNNEL" "IMAGE" "$c_reset"
            printf "%s%-32s  %-24s  %-30s  %-16s  %s%s\n" \
                "$c_dim" "────────────────────────────────" "────────────────────────" \
                "──────────────────────────────" "────────────────" "────────────────────────" "$c_reset"
        else
            printf "%s%-32s  %-24s  %-12s  %s%s\n" \
                "$c_bold" "HOSTNAME" "NAME" "TARGET" "IMAGE" "$c_reset"
            printf "%s%-32s  %-24s  %-12s  %s%s\n" \
                "$c_dim" "────────────────────────────────" "────────────────────────" "────────────" "────────────────────────" "$c_reset"
        end
        for line in $results
            # f: hostname path name image port protocol service tunnel
            set -l f (string split \t -- $line)
            # ($hostname is a read-only special variable in fish)
            set -l route $f[1]
            test -n "$f[2]"; and set route "$f[1] $f[2]"
            if test "$verbose" = true
                printf "%s%-32s%s  %s%-24s%s  %s%-30s%s  %-16s  %s\n" \
                    "$c_green" "$route" "$c_reset" "$c_cyan" "$f[3]" "$c_reset" \
                    "$c_yellow" "$f[7]" "$c_reset" "$f[8]" "$f[4]"
            else
                set -l target $f[6]
                test -n "$f[5]"; and set target "$f[5]/$f[6]"
                printf "%s%-32s%s  %s%-24s%s  %s%-12s%s  %s\n" \
                    "$c_green" "$route" "$c_reset" "$c_cyan" "$f[3]" "$c_reset" \
                    "$c_yellow" "$target" "$c_reset" "$f[4]"
            end
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
    dports -n nginx             Filter by container name containing \"nginx\"
    dports -i postgres          Filter by image name containing \"postgres\"
    dports -n web -p 80         Combine filters (AND logic)
    dports -q                   List only port numbers
    dports -j                   Output as JSON array
    dports -t                   Also list hostnames served through Cloudflare Tunnel
    dports -t -j                Tunnel routes only, as JSON

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
