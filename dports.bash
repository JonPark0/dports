#!/usr/bin/env bash
#
# dports - Display Docker container port mappings
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.6.0
# License: MIT
#
# This file is the whole implementation. The Fish and Zsh front ends
# (dports.fish, dports.zsh) run it with bash.
#
# Installation:
#   Apt:  sudo apt install dports  (Forgejo package registry)
#   Bash: Copy to ~/.bash_functions/dports and source from ~/.bashrc,
#         or run it directly: bash dports.bash [OPTIONS]
#

DPORTS_VERSION="2.6.0"

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
    local interactive=false
    # Engines (see _dports_engines_resolve); settings may come from config
    local engine_opt="" engines_src="" cfg_engines="" cfg_engines_src="" cfg_refresh="" cfg_timeout=""
    local _dports_dk=docker
    local -a engines=() dk_engines=() ic_engines=() engines_failed=()
    local DPORTS_TIMEOUT="${DPORTS_TIMEOUT:-}" DPORTS_REFRESH="${DPORTS_REFRESH:-}"

    # Help function (local to dports)
    _dports_usage() {
        cat <<'EOF'
dports - Display Docker container port mappings

USAGE:
    dports [OPTIONS]
    dports -I [-t] [-a] [FILTERS]
    dports update [--check | --yes] [--recreate]
    dports engines

SUBCOMMANDS:
    update              Check running containers' images for updates, pull
                        them and recreate the containers that use them
                        (see 'dports update --help')
    engines             Show which container engines are installed, detected
                        and in use, and how to choose them

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
    -I, --interactive   Browse ports (and tunnel routes with -t) in a
                        full-screen view: search, details, logs, restart,
                        shell (EXPERIMENTAL)
    --engine LIST       Use these engines for this run: docker, podman,
                        incus, lxd or auto, comma-separated
    -h, --help          Show this help message
    -V, --version       Show version information

EXAMPLES:
    dports                      List all running containers with exposed ports
    dports update               Check, pull and recreate interactively
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
    dports -I -t                Browse ports and tunnel routes interactively
    dports -q | xargs -I{}      Pipe ports to another command

OUTPUT COLUMNS:
    PORT        Host port (external)
    NAME        Container name
    INTERNAL    Internal port with protocol (verbose mode only)
    IMAGE       Docker image name
    ENGINE      Container engine (when more than one is in use)

ENGINES:
    Docker, Podman, Incus and LXD are supported. Without configuration,
    dports uses every engine whose socket or storage exists (no daemon is
    contacted to find out). To choose, set in ~/.config/dports/config or
    /etc/dports.conf:
        engines = docker,incus
    DPORTS_ENGINES or --engine override it for one run. The same files
    also take "refresh = 5" (dports -I) and "timeout = 30" (registry
    queries). 'dports engines' shows what is installed and in use.
    For Incus and LXD, ports are their proxy devices and network forwards
    (reading them needs jq or python3).

EOF
    }

    # ── Terminal UI toolkit ────────────────────────────────────────────────────
    # Every full-screen view runs in a subshell ($(...) or ( ... )), so its
    # traps, variables and terminal settings never leak into the calling
    # shell. Frames are drawn on fd 3 (/dev/tty), keys are read from it too.

    # _dports_fit VAR TEXT WIDTH: store TEXT cut or padded to WIDTH columns in VAR
    _dports_fit() {
        local __fit_s="$2" __fit_w="$3"
        if (( __fit_w <= 0 )); then printf -v "$1" '%s' ''; return; fi
        if (( ${#__fit_s} > __fit_w )); then
            __fit_s="${__fit_s:0:__fit_w-1}${_dports_ell:-~}"
        fi
        printf -v "$1" '%s%*s' "$__fit_s" $(( __fit_w - ${#__fit_s} )) ''
    }

    # _dports_fit_list VAR LIST WIDTH: keep the leading names of a
    # comma-separated LIST that fit in WIDTH and add "+N more" for the rest
    _dports_fit_list() {
        local __fl_list="$2" __fl_w="$3" __fl_out="" __fl_try __fl_rest __fl_k
        local -a __fl_names=()
        if (( ${#__fl_list} <= __fl_w )); then printf -v "$1" '%s' "$__fl_list"; return; fi
        IFS=$'\n' read -r -d '' -a __fl_names <<<"${__fl_list//, /$'\n'}"
        for (( __fl_k = 0; __fl_k < ${#__fl_names[@]}; __fl_k++ )); do
            __fl_try="${__fl_out:+$__fl_out, }${__fl_names[__fl_k]}"
            __fl_rest=$(( ${#__fl_names[@]} - __fl_k - 1 ))
            (( __fl_rest > 0 )) && __fl_try+=", +$__fl_rest more"
            (( ${#__fl_try} <= __fl_w )) || break
            __fl_out="${__fl_out:+$__fl_out, }${__fl_names[__fl_k]}"
        done
        __fl_rest=$(( ${#__fl_names[@]} - __fl_k ))
        if [[ -z "$__fl_out" ]]; then
            __fl_out="+$__fl_rest containers"
        elif (( __fl_rest > 0 )); then
            __fl_out+=", +$__fl_rest more"
        fi
        printf -v "$1" '%s' "$__fl_out"
    }

    # Open the terminal for a full-screen view. Returns 1 without a terminal.
    _dports_tui_init() {
        [[ "${TERM:-dumb}" != dumb ]] || return 1
        exec 3<>/dev/tty 2>/dev/null || return 1
        e=$'\033'
        t_rev="${e}[7m" t_reset="${e}[0m"
        t_bold="" t_dim="" t_green="" t_yellow="" t_cyan="" t_red=""
        if [[ -n "$C_RESET" ]]; then
            t_bold="${e}[1m" t_dim="${e}[2m" t_green="${e}[32m"
            t_yellow="${e}[33m" t_cyan="${e}[36m" t_red="${e}[31m"
        fi
        _dports_ell='~'
        [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]*8* ]] && _dports_ell='…'
        tui_saved=$(stty -g <&3 2>/dev/null)
        tui_tmp=$(mktemp -d) || return 1
        trap '_dports_tui_leave; rm -rf "$tui_tmp"' EXIT
        # Ctrl+C raises SIGINT (`read -n` re-enables signal keys): leave
        # through the EXIT trap so the terminal is always restored
        trap 'exit 130' INT TERM HUP
        _dports_tui_resume
    }

    # Enter the alternate screen; _dports_tui_leave goes back (e.g. for a shell)
    _dports_tui_resume() {
        stty -echo -icanon <&3 2>/dev/null
        printf '%s' "${e}[?1049h${e}[?25l" >&3
    }
    _dports_tui_leave() {
        printf '%s' "${e}[?25h${e}[?1049l" >&3
        [[ -n "${tui_saved:-}" ]] && stty "$tui_saved" <&3 2>/dev/null
    }

    # Set rows/cols from the terminal (cols excludes the last column)
    _dports_tui_size() {
        local size
        size=$(stty size <&3 2>/dev/null)
        rows=${size% *} cols=${size#* }
        [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ && "$rows" -gt 0 ]] || { rows=24 cols=80; }
        (( cols -= 1 ))
        printf -v tui_rule '%*s' "$cols" ''
        tui_rule="${tui_rule// /─}"
    }

    # _dports_tui_readkey TIMEOUT: set key to a name (up down left right
    # pgup pgdn home end enter space tab backspace esc) or the character.
    # Returns 1 on timeout, 2 when the terminal is gone.
    _dports_tui_readkey() {
        local c rest rc
        key=""
        IFS= read -rsn1 -t "$1" -u 3 key
        rc=$?
        (( rc > 128 )) && return 1
        (( rc != 0 )) && return 2
        case "$key" in
            "")             key=enter ;;
            " ")            key=space ;;
            $'\t')          key=tab ;;
            $'\177'|$'\b')  key=backspace ;;
            "$e")
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
                    "")                     key=esc ;;
                    "[A"|OA)                key=up ;;
                    "[B"|OB)                key=down ;;
                    "[C"|OC)                key=right ;;
                    "[D"|OD)                key=left ;;
                    "[5~")                  key=pgup ;;
                    "[6~")                  key=pgdn ;;
                    "[H"|OH|"[1~"|"[7~")    key=home ;;
                    "[F"|OF|"[4~"|"[8~")    key=end ;;
                    "[Z")                   key=tab ;;
                    *)                      key=ignore ;;
                esac ;;
        esac
        return 0
    }

    # _dports_tui_scroll N LIST_H: keep cur within 0..N-1 and visible
    _dports_tui_scroll() {
        local n="$1" h="$2"
        (( cur > n - 1 )) && cur=$(( n - 1 ))
        (( cur < 0 )) && cur=0
        (( cur < top )) && top=$cur
        (( cur >= top + h )) && top=$(( cur - h + 1 ))
        (( top > n - h )) && top=$(( n - h ))
        (( top < 0 )) && top=0
    }

    # _dports_tui_move N PAGE: apply a movement key to cur
    _dports_tui_move() {
        case "$key" in
            up|k)       (( cur-- )) ;;
            down|j)     (( cur++ )) ;;
            pgup)       (( cur -= $2 )) ;;
            pgdn)       (( cur += $2 )) ;;
            home|g)     cur=0 ;;
            end|G)      cur=$(( $1 - 1 )) ;;
            *)          return 1 ;;
        esac
        (( cur > $1 - 1 )) && cur=$(( $1 - 1 ))
        (( cur < 0 )) && cur=0
        return 0
    }

    # _dports_tui_line VAR COLOR TEXT: a full-width line (cut to cols)
    _dports_tui_line() {
        local __tl_s
        _dports_fit __tl_s "$3" "$cols"
        printf -v "$1" '%s%s%s%s' "$2" "$__tl_s" "$t_reset" "${e}[K"
    }

    # Replace control characters (escape sequences in logs) by visible text
    _dports_tui_clean() {
        local __tc_s="${2//$'\r'/}"
        __tc_s="${__tc_s//$'\033'/^[}"
        __tc_s="${__tc_s//$'\t'/    }"
        printf -v "$1" '%s' "$__tc_s"
    }

    # ── Engines ────────────────────────────────────────────────────────────────
    # docker and podman share the docker CLI's commands and output formats
    # ("docker-family"); incus and lxd (lxc CLI) are read through their REST
    # API with `incus query`. Only the engines in use are ever called, and
    # auto-detection only looks at the file system, never at a daemon.

    # Run the docker-family CLI of the current engine (_dports_dk)
    _dk() { command "${_dports_dk:-docker}" "$@"; }

    # Name of the command that drives ENGINE
    _dports_engine_cli() {
        case "$1" in lxd) echo lxc ;; *) echo "$1" ;; esac
    }

    # Read KEY=VALUE settings from /etc/dports.conf, then the user's
    # ~/.config/dports/config; DPORTS_ENGINES, DPORTS_REFRESH and
    # DPORTS_TIMEOUT in the environment take precedence.
    _dports_config_load() {
        local f key val line
        cfg_engines="" cfg_engines_src="" cfg_refresh="" cfg_timeout=""
        for f in /etc/dports.conf "${XDG_CONFIG_HOME:-$HOME/.config}/dports/config"; do
            [[ -r "$f" ]] || continue
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"
                [[ "$line" == *=* ]] || continue
                key="${line%%=*}" val="${line#*=}"
                key="${key//[[:space:]]/}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                case "$key" in
                    engines)    cfg_engines="$val" cfg_engines_src="$f" ;;
                    refresh)    cfg_refresh="$val" ;;
                    timeout)    cfg_timeout="$val" ;;
                esac
            done < "$f"
        done
        if [[ -n "${DPORTS_ENGINES:-}" ]]; then
            cfg_engines="$DPORTS_ENGINES" cfg_engines_src="DPORTS_ENGINES"
        fi
    }

    # Does ENGINE look usable? Only checks that its command is installed and
    # that its socket or storage exists: no daemon is contacted.
    _dports_engine_present() {
        local f head=""
        case "$1" in
            docker)
                f=$(command -v docker 2>/dev/null) || return 1
                # podman-docker installs a "docker" script that runs podman
                [[ -f "$f" ]] && IFS= read -r -d '' -N 512 head < "$f" 2>/dev/null
                [[ "$head" == "#!"*podman* ]] && return 1
                [[ -n "${DOCKER_HOST:-}" || -n "${DOCKER_CONTEXT:-}" || -S /var/run/docker.sock \
                   || -S /run/docker.sock || -S "${XDG_RUNTIME_DIR:-/run/user/$UID}/docker.sock" \
                   || -d "${DOCKER_CONFIG:-$HOME/.docker}/contexts/meta" ]] ;;
            podman)
                command -v podman &>/dev/null || return 1
                if (( EUID == 0 )); then
                    [[ -d /var/lib/containers/storage ]]
                else
                    [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage" ]]
                fi ;;
            incus)
                command -v incus &>/dev/null || return 1
                [[ -n "${INCUS_DIR:-}" || -S /var/lib/incus/unix.socket \
                   || -S /run/incus/unix.socket.user || -S /var/lib/incus/unix.socket.user ]] ;;
            lxd)
                command -v lxc &>/dev/null || return 1
                [[ -n "${LXD_DIR:-}" || -S /var/snap/lxd/common/lxd/unix.socket || -S /var/lib/lxd/unix.socket ]] ;;
            *)  return 1 ;;
        esac
    }

    # Set engines=(...) from --engine, DPORTS_ENGINES, the config files or
    # auto-detection; engines_src says which one decided
    _dports_engines_resolve() {
        local list="${engine_opt:-$cfg_engines}" e a
        engines=()
        if [[ -n "$engine_opt" ]]; then engines_src="--engine"
        elif [[ -n "$cfg_engines" ]]; then engines_src="$cfg_engines_src"
        else engines_src="auto"; fi
        for e in ${list//,/ }; do
            case "$e" in
                docker|podman|incus|lxd)
                    [[ " ${engines[*]} " == *" $e "* ]] || engines+=("$e") ;;
                auto)
                    for a in docker podman incus lxd; do
                        _dports_engine_present "$a" && [[ " ${engines[*]} " != *" $a "* ]] && engines+=("$a")
                    done ;;
                *)
                    echo "Error: unknown engine '$e' (use docker, podman, incus, lxd or auto)" >&2
                    return 1 ;;
            esac
        done
        if [[ -z "$list" ]]; then
            for a in docker podman incus lxd; do
                _dports_engine_present "$a" && engines+=("$a")
            done
        fi
        # Nothing found: try docker (it may use a remote context)
        (( ${#engines[@]} )) || engines=(docker)
        dk_engines=() ic_engines=()
        for e in "${engines[@]}"; do
            case "$e" in docker|podman) dk_engines+=("$e") ;; *) ic_engines+=("$e") ;; esac
        done
        return 0
    }

    # dports engines: what is installed, detected and in use
    _dports_engines_report() {
        local e cli inst det act
        printf "${C_BOLD}%-8s  %-9s  %-8s  %-6s  %s${C_RESET}\n" "ENGINE" "INSTALLED" "DETECTED" "ACTIVE" "COMMAND"
        for e in docker podman incus lxd; do
            cli=$(_dports_engine_cli "$e")
            inst=no; command -v "$cli" &>/dev/null && inst=yes
            det=no; _dports_engine_present "$e" && det=yes
            act=no; [[ " ${engines[*]} " == *" $e "* ]] && act=yes
            printf "%-8s  %-9s  %-8s  %-6s  %s\n" "$e" "$inst" "$det" "$act" "$cli"
        done
        echo
        case "$engines_src" in
            auto)       echo "Active engines: auto-detected from sockets and storage (no daemon was contacted)." ;;
            --engine)   echo "Active engines: chosen with --engine." ;;
            *)          echo "Active engines: set in $engines_src." ;;
        esac
        echo "To choose them, put engines=docker,incus (any of docker, podman, incus, lxd, auto)"
        echo "in ${XDG_CONFIG_HOME:-$HOME/.config}/dports/config or /etc/dports.conf,"
        echo "or use DPORTS_ENGINES=... or --engine ... for one run."
    }

    # Report an engine that could not be reached (when others are in use)
    _dports_engine_warn() {
        (( ${#engines[@]} > 1 )) && echo "Note: cannot reach $1; it is left out." >&2
        engines_failed+=("$1")
    }

    # Run `incus query PATH` (or lxc) and turn the JSON into tab-separated
    # records with jq or python3. KIND: instances, instance, networks, forwards.
    #   instances: X name project status image type
    #              D name project listen connect            (proxy devices)
    #              A name project address interface         (with state)
    #   networks:  the names of managed networks
    #   forwards:  F listen_address listen_port protocol target_address target_port
    _dports_ic_query() {
        local cli="$1" path="$2" kind="$3" json
        json=$("$cli" query "$path" 2>/dev/null) || return 1
        if command -v jq &>/dev/null; then
            case "$kind" in
                instances|instance)
                    jq -r '(if type == "array" then .[] else . end) | . as $i
                        | ($i.project // "default") as $p
                        | (["X", $i.name, $p, $i.status,
                            ($i.config["image.description"]
                             // ((($i.config["image.os"] // "") + " " + ($i.config["image.release"] // ""))
                                 | sub("^ +"; "") | sub(" +$"; ""))),
                            ($i.type // "")] | @tsv),
                          (($i.expanded_devices // {}) | to_entries[] | select(.value.type == "proxy")
                            | ["D", $i.name, $p, (.value.listen // ""), (.value.connect // "")] | @tsv),
                          (($i.state.network // {}) | to_entries[] | select(.key != "lo") | .key as $if
                            | (.value.addresses // [])[] | select(.family == "inet" and .scope == "global")
                            | ["A", $i.name, $p, .address, $if] | @tsv)' <<<"$json" ;;
                networks)
                    jq -r '.[] | select(.managed) | .name' <<<"$json" ;;
                forwards)
                    jq -r '.[] | . as $f
                        | ((.ports // [])[] | ["F", $f.listen_address, .listen_port, .protocol,
                            (.target_address // ""), (.target_port // "")] | @tsv),
                          (if (($f.config // {}).target_address // "") != ""
                           then ["F", $f.listen_address, "*", "*", $f.config.target_address, "*"] | @tsv
                           else empty end)' <<<"$json" ;;
            esac
        elif command -v python3 &>/dev/null; then
            python3 -c '
import json, sys
kind, data = sys.argv[1], json.load(sys.stdin)
out = lambda *f: print("\t".join(str(x) for x in f))
if kind in ("instances", "instance"):
    for i in (data if isinstance(data, list) else [data]):
        p, c = i.get("project") or "default", i.get("config") or {}
        img = c.get("image.description") or (c.get("image.os", "") + " " + c.get("image.release", "")).strip()
        out("X", i["name"], p, i.get("status", ""), img, i.get("type", ""))
        for d in (i.get("expanded_devices") or {}).values():
            if d.get("type") == "proxy":
                out("D", i["name"], p, d.get("listen", ""), d.get("connect", ""))
        for ifname, n in ((i.get("state") or {}).get("network") or {}).items():
            if ifname == "lo":
                continue
            for a in n.get("addresses") or []:
                if a.get("family") == "inet" and a.get("scope") == "global":
                    out("A", i["name"], p, a["address"], ifname)
elif kind == "networks":
    for n in data:
        if n.get("managed"):
            print(n["name"])
elif kind == "forwards":
    for f in data:
        for p in f.get("ports") or []:
            out("F", f["listen_address"], p.get("listen_port", ""), p.get("protocol", ""),
                p.get("target_address", ""), p.get("target_port", ""))
        t = (f.get("config") or {}).get("target_address", "")
        if t:
            out("F", f["listen_address"], "*", "*", t, "*")
' "$kind" <<<"$json"
        else
            echo "Note: reading $cli needs jq or python3; it is left out." >&2
            return 1
        fi
    }

    # Records of an Incus/LXD engine: the instances (with addresses when
    # WITH_STATE is true) and the forwards of its managed networks
    _dports_ic_records() {
        local e="$1" with_state="${2:-false}" cli recs nets net fw=""
        cli=$(_dports_engine_cli "$e")
        nets=$(_dports_ic_query "$cli" "/1.0/networks?recursion=1" networks) || nets=""
        for net in $nets; do
            fw+=$(_dports_ic_query "$cli" "/1.0/networks/$net/forwards?recursion=1" forwards)$'\n'
        done
        # Addresses are only needed to name the targets of forwards (and
        # tunnel routes), so the cheaper listing is used otherwise
        [[ "$fw" == *F$'\t'* ]] && with_state=true
        if [[ "$with_state" == true ]]; then
            recs=$(_dports_ic_query "$cli" "/1.0/instances?recursion=2&all-projects=true" instances) || return 1
        else
            recs=$(_dports_ic_query "$cli" "/1.0/instances?recursion=1&all-projects=true" instances) || return 1
        fi
        printf '%s\n%s\n' "$recs" "$fw"
    }

    # Published ports of an Incus/LXD engine:
    # PORT NAME INTERNAL IMAGE ENGINE, from the proxy devices of the
    # instances (running ones, or all with -a) and the network forwards
    _dports_ic_rows() {
        local e="$1" recs
        recs=$(_dports_ic_records "$e") || return 1
        awk -F'\t' -v engine="$e" -v show_all="$show_all" '
            function disp(n, p) { return (p == "default" || p == "") ? n : p "/" n }
            # "tcp:0.0.0.0:80,443" -> proto and port list
            function split_addr(s, parts,    i) {
                parts["proto"] = s; sub(/:.*/, "", parts["proto"])
                i = s; sub(/^[^:]*:/, "", i)
                if (i ~ /^\[/) { sub(/^\[[^]]*\]/, "", i); sub(/^:/, "", i) }
                else sub(/^[^:]*:/, "", i)
                parts["ports"] = i
            }
            $1 == "X" { k = $2 SUBSEP $3; status[k] = $4; img[k] = ($5 == "" ? "-" : $5); name[k] = disp($2, $3); next }
            $1 == "D" { dev[++nd] = $0; next }
            $1 == "A" { byip[$4] = $2 SUBSEP $3; next }
            $1 == "F" { fw[++nf] = $0; next }
            END {
                for (d = 1; d <= nd; d++) {
                    split(dev[d], f, "\t"); k = f[2] SUBSEP f[3]
                    if (show_all != "true" && status[k] != "Running") continue
                    split_addr(f[4], L); split_addr(f[5], C)
                    if (L["proto"] == "unix" || L["ports"] == "") continue
                    internal = C["ports"] (C["proto"] == "unix" ? "" : "/" C["proto"])
                    if (C["proto"] == "unix") internal = f[5]
                    n = split(L["ports"], ports, ",")
                    for (i = 1; i <= n; i++)
                        printf "%s\t%s\t%s\t%s\t%s\n", ports[i], name[k], internal, img[k], engine
                }
                for (j = 1; j <= nf; j++) {
                    split(fw[j], f, "\t")
                    lp = f[3]; proto = f[4]; ta = f[5]; tp = (f[6] == "" ? f[3] : f[6])
                    if (ta in byip) { k = byip[ta]; who = name[k]; im = img[k] }
                    else { who = "(" ta ")"; im = "-" }
                    n = split(lp, ports, ","); nt = split(tp, tps, ",")
                    for (i = 1; i <= n; i++) {
                        t = (nt == n ? tps[i] : tp)
                        printf "%s\t%s\t%s\t%s\t%s\n", ports[i], who, (t == "*" ? "*" : t "/" proto), im, engine
                    }
                }
            }' <<<"$recs"
    }

    # ── update helpers ─────────────────────────────────────────────────────────

    _dports_update_usage() {
        cat <<'EOF'
dports update - Check running containers' images for updates, pull them and
recreate the containers that use them

USAGE:
    dports update [OPTIONS]

OPTIONS:
    --check             Only report the status of each image; pull nothing
    -y, --yes           Pull every image that has an update, without asking
    --recreate          After pulling, recreate every Compose service (or
                        Podman systemd unit) that runs an older image than
                        its tag, without asking
    --engine LIST       Engines to check: docker, podman (Incus and LXD
                        instances are not pulled from registries)
    -c, --color         Force color output
    -C, --no-color      Disable color output
    -h, --help          Show this help message

STATUS:
    update      The registry has a newer image (selected by default)
    current     The local image matches the registry
    pinned      Referenced by digest, so pulling never changes it
    local       Built locally or loaded from a file (not in the registry)
    unknown     The registry could not be asked or gave no clear answer

INTERACTIVE SCREENS:
    Checking    Live status of every image; q quits
    Images      Up/Down, j/k move   Space toggle   u updates   a all   n none
                Enter pull the selected images   r recreate screen   q quit
    Pulling     Live progress of every pull
    Recreate    Containers whose image is older than their tag. Enter
                recreates the one under the cursor, Space selects, s
                recreates the selected ones, A all of them; Tab moves to
                the buttons; q done

Compose services are recreated with "docker compose up -d" (Podman:
"podman compose up -d --force-recreate"); Podman containers run by systemd
(Quadlet, PODMAN_SYSTEMD_UNIT) by restarting their unit. Other containers
are listed but have to be recreated by hand (with their original run
options). For Podman, skopeo makes the registry check exact.
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
        if ! inspect=$(_dk image inspect "$image" \
                --format '{{.Id}}{{range .RepoDigests}} {{.}}{{end}}' 2>/dev/null) || [[ -z "$inspect" ]]; then
            printf 'unknown\tThe image is no longer present locally\n'; return
        fi
        local_id="${inspect%% *}"
        for ref in ${inspect#"$local_id"}; do
            repo_digests+="${ref##*@} "
        done
        # Podman prints image IDs without the "sha256:" prefix
        [[ "$local_id" == sha256:* ]] || local_id="sha256:$local_id"
        if [[ "$repo_digests" == " " ]]; then
            printf 'local\tNo registry digest: built locally or loaded from a file\n'; return
        fi

        local remote_digest="" out rc errs="" err_rc=0
        if [[ "$_dports_dk" == podman ]]; then
            _dports_check_podman
            return
        fi

        # Preferred: buildx reports the top-level (index) digest directly.
        # Parse its default output: older buildx releases ignore --format.
        if _dk buildx version &>/dev/null; then
            out=$(_dports_registry "${_dports_dk:-docker}" buildx imagetools inspect "$image" 2>&1); rc=$?
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
            "${_dports_dk:-docker}" manifest inspect -v "$image" 2>&1); rc=$?
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

    # Registry check for podman, which has no buildx: skopeo reports the
    # top-level digest; otherwise `podman manifest inspect` reads the
    # manifest (list), whose platform entry podman records in RepoDigests.
    # Uses image, local_id, repo_digests, os, arch, variant of the caller.
    _dports_check_podman() {
        local out rc fields kind plat cfg
        if [[ "$image" == localhost/* ]]; then
            printf 'local\tBuilt locally (a localhost/ image)\n'; return
        fi
        if command -v skopeo &>/dev/null; then
            out=$(_dports_registry skopeo inspect --format '{{.Digest}}' "docker://$image" 2>&1); rc=$?
            if (( rc == 0 )) && [[ "$out" == sha256:* ]]; then
                if [[ "$repo_digests" == *" $out "* ]]; then
                    printf 'current\tMatches the registry\n'
                else
                    printf 'update\tThe registry has a newer image\n'
                fi
                return
            fi
            errs="$out" err_rc=$rc
        fi
        out=$(_dports_registry podman manifest inspect "$image" 2>&1); rc=$?
        if (( rc != 0 )) || [[ "${out:0:1}" != "{" ]]; then
            (( rc == 124 )) && err_rc=124
            _dports_registry_error "$image" "$errs"$'\n'"$out" "$err_rc"
            return
        fi
        if command -v jq &>/dev/null; then
            fields=$(jq -r --arg os "$os" --arg arch "$arch" --arg variant "$variant" '
                if .manifests then
                    ["list", ([.manifests[] | select(.platform.os == $os and .platform.architecture == $arch
                        and ($variant == "" or (.platform.variant // "") == $variant))][0].digest // ""), ""]
                else ["single", "", (.config.digest // "")] end | join(" ")' <<<"$out" 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            fields=$(python3 -c '
import sys, json
os_, arch, variant = sys.argv[1:4]
d = json.load(sys.stdin)
if "manifests" in d:
    m = [x for x in d["manifests"] if (x.get("platform") or {}).get("os") == os_
         and (x.get("platform") or {}).get("architecture") == arch
         and (not variant or (x.get("platform") or {}).get("variant", "") == variant)]
    print("list", m[0]["digest"] if m else "", "")
else:
    print("single", "", (d.get("config") or {}).get("digest", ""))
' "$os" "$arch" "$variant" <<<"$out" 2>/dev/null)
        else
            printf 'unknown\tInstall skopeo, jq or python3 to compare digests\n'; return
        fi
        read -r kind plat cfg <<<"$fields"
        if [[ "$kind" == list ]]; then
            if [[ "$plat" != sha256:* ]]; then
                printf 'unknown\tThe registry has no manifest for %s\n' "$platform"
            elif [[ "$repo_digests" == *" $plat "* ]]; then
                printf 'current\tMatches the registry\n'
            else
                printf 'update\tThe registry has a newer image\n'
            fi
        elif [[ "$cfg" == sha256:* ]]; then
            if [[ "$cfg" == "$local_id" ]]; then
                printf 'current\tMatches the registry\n'
            else
                printf 'update\tThe registry has a newer image\n'
            fi
        else
            printf 'unknown\tThe registry gave an unexpected manifest\n'
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

    # Set platform to the daemon's OS/ARCH[/VARIANT] as registries name it
    _dports_platform() {
        local fmt='{{.OSType}}/{{.Architecture}}'
        [[ "$_dports_dk" == podman ]] && fmt='{{.Host.OS}}/{{.Host.Arch}}{{if .Host.Variant}}/{{.Host.Variant}}{{end}}'
        if ! platform=$(_dk info --format "$fmt" 2>/dev/null) || [[ -z "$platform" ]]; then
            return 1
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
    }

    # Start checking every image in the background; results land in DIR/<i>
    # and DIR/done appears when all checks are over.
    _dports_check_start() {
        local dir="$1" i
        mkdir -p "$dir" || return 1
        # The double subshell keeps an interactive shell from printing
        # job-control notices and from waiting on the workers.
        (
            (
                for (( i = 0; i < n; i++ )); do
                    while (( $(jobs -rp | wc -l) >= 8 )); do wait -n 2>/dev/null; done
                    {
                        _dports_dk="${img_eng[i]}"
                        _dports_check_image_update "${images[i]}" "$platform" > "$dir/$i.tmp" 2>/dev/null
                        mv -f "$dir/$i.tmp" "$dir/$i"
                    } &
                done
                wait
                : > "$dir/done"
            ) &
            echo $! > "$dir/pid"
        )
    }

    # _dports_check_poll DIR: read finished results into st/detail; sets
    # checked (count) and returns 0 once every check is over
    _dports_check_poll() {
        local dir="$1" i pid
        checked=0
        for (( i = 0; i < n; i++ )); do
            if [[ -z "${st[i]}" && -e "$dir/$i" ]]; then
                IFS=$'\t' read -r "st[i]" "detail[i]" 2>/dev/null < "$dir/$i"
                [[ -n "${st[i]}" ]] || st[i]=unknown detail[i]="The check gave no answer"
            fi
            [[ -n "${st[i]}" ]] && (( checked++ ))
        done
        (( checked == n )) && return 0
        pid=$(cat "$dir/pid" 2>/dev/null)
        if [[ -e "$dir/done" || ! -d "$dir" ]] || { [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; }; then
            for (( i = 0; i < n; i++ )); do
                [[ -n "${st[i]}" ]] || st[i]=unknown detail[i]="The check did not finish"
            done
            checked=$n
            return 0
        fi
        return 1
    }

    # Containers that run an older image than the one their tag points to
    # now (pulled since they were created), for every docker-family engine.
    # Fills the r_* arrays, one entry per Compose service, per systemd unit
    # (Podman Quadlet or generated units), or per other container
    # (r_kind manual: recreate it by hand with its original run options).
    _dports_outdated() {
        r_label=() r_names=() r_image=() r_dir=() r_proj=() r_files=() r_svc=() r_ok=()
        r_eng=() r_kind=() r_unit=()
        local ids line name cimg run proj dir files svc unit key k e
        local -A cur_id=() idx=()
        local -a lines=()
        for e in "${dk_engines[@]}"; do
            _dports_dk=$e
            ids=$(_dk ps -q 2>/dev/null)
            [[ -n "$ids" ]] || continue
            # shellcheck disable=SC2086
            mapfile -t lines < <(_dk inspect --format '{{.Name}}{{"\t"}}{{.Config.Image}}{{"\t"}}{{.Image}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project.working_dir"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project.config_files"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' \
                $ids 2>/dev/null | tr '\t' '\037' | sort)
            for line in "${lines[@]}"; do
                IFS=$'\037' read -r name cimg run proj dir files svc unit <<<"$line"
                name="${name#/}"
                [[ -n "$cimg" && -n "$run" ]] || continue
                if [[ -z "${cur_id[$e|$cimg]+x}" ]]; then
                    cur_id[$e|$cimg]=$(_dk image inspect --format '{{.Id}}' "$cimg" 2>/dev/null)
                fi
                [[ -n "${cur_id[$e|$cimg]}" && "${cur_id[$e|$cimg]}" != "$run" ]] || continue
                # Compose labels win: podman-compose also sets PODMAN_SYSTEMD_UNIT
                if [[ -n "$proj" && -n "$dir" && -n "$svc" ]]; then
                    key="$e|$proj|$dir|$svc"
                elif [[ -n "$unit" ]]; then
                    key="$e|unit|$unit"
                else
                    key="$e|!$name"
                fi
                if [[ -n "${idx[$key]+x}" ]]; then
                    k=${idx[$key]}
                    r_names[k]+=", $name"
                    continue
                fi
                k=${#r_label[@]}
                idx[$key]=$k
                r_names[k]="$name" r_image[k]="$cimg" r_dir[k]="$dir" r_proj[k]="$proj"
                r_files[k]="$files" r_svc[k]="$svc" r_eng[k]="$e" r_unit[k]="$unit"
                case "$key" in
                    *"|unit|"*) r_label[k]="$unit" r_ok[k]=1 r_kind[k]=systemd ;;
                    *"|!"*)     r_label[k]="$name" r_ok[k]=0 r_kind[k]=manual ;;
                    *)          r_label[k]="$proj/$svc" r_ok[k]=1 r_kind[k]=compose ;;
                esac
            done
        done
    }

    # The command that recreates item K, as shown to the user
    _dports_recreate_cmd() {
        local k="$1"
        case "${r_kind[k]}" in
            compose)    printf 'cd %q && %s compose up -d %s%s' "${r_dir[k]}" "${r_eng[k]}" \
                            "$([[ "${r_eng[k]}" == podman ]] && echo '--force-recreate ')" "${r_svc[k]}" ;;
            systemd)    printf 'systemctl %srestart %s' "$( (( EUID == 0 )) || echo '--user ')" "${r_unit[k]}" ;;
            *)          printf '%s' "Not managed by Compose or systemd: recreate it with its original run options" ;;
        esac
    }

    # _dports_compose_up K: recreate item K (docker/podman compose up -d,
    # or restart its systemd unit, which recreates the container)
    _dports_compose_up() {
        local k="$1" f
        if [[ "${r_kind[k]}" == systemd ]]; then
            if (( EUID == 0 )); then
                systemctl restart "${r_unit[k]}" 2>&1
            else
                systemctl --user restart "${r_unit[k]}" 2>&1
            fi
            return
        fi
        local -a args=(compose -p "${r_proj[k]}") files=()
        if [[ ! -d "${r_dir[k]}" ]]; then
            echo "The Compose project directory is not on this host: ${r_dir[k]}"
            return 1
        fi
        # (podman-compose records the files relative to the project directory)
        IFS=, read -ra files <<<"${r_files[k]}"
        for f in "${files[@]}"; do [[ -n "$f" ]] && args+=(-f "$f"); done
        args+=(up -d --no-deps)
        # podman-compose does not notice that the tag points to a new image
        [[ "${r_eng[k]}" == podman ]] && args+=(--force-recreate)
        args+=("${r_svc[k]}")
        ( cd "${r_dir[k]}" && command "${r_eng[k]:-docker}" "${args[@]}" ) 2>&1
    }

    # Print how to recreate the outdated containers that are left
    # (items whose r_state is not "recreated")
    _dports_outdated_report() {
        local k d
        local -A dir_svcs=()
        local -a dirs=() units=() manual=()
        for (( k = 0; k < ${#r_label[@]}; k++ )); do
            [[ "${r_state[k]:-}" == recreated ]] && continue
            case "${r_kind[k]}" in
                compose)    dir_svcs["${r_eng[k]}|${r_dir[k]}"]+=" ${r_svc[k]}" ;;
                systemd)    units+=("${r_unit[k]}") ;;
                *)          manual+=("${r_label[k]}") ;;
            esac
        done
        (( ${#dir_svcs[@]} + ${#units[@]} + ${#manual[@]} )) || return 0
        echo
        echo "Running an older image than their tag (recreate them to use the new one):"
        mapfile -t dirs < <(printf '%s\n' "${!dir_svcs[@]}" | sed '/^$/d' | sort)
        for d in "${dirs[@]}"; do
            printf "  ${C_CYAN}cd %q && %s compose up -d%s%s${C_RESET}\n" "${d#*|}" "${d%%|*}" \
                "$([[ "${d%%|*}" == podman ]] && echo ' --force-recreate')" "${dir_svcs[$d]}"
        done
        for d in "${units[@]}"; do
            printf "  ${C_CYAN}systemctl %srestart %s${C_RESET}\n" "$( (( EUID == 0 )) || echo '--user ')" "$d"
        done
        for d in "${manual[@]}"; do
            printf "  ${C_CYAN}%s${C_RESET} ${C_DIM}(not managed by Compose or systemd: recreate it with its original run options)${C_RESET}\n" "$d"
        done
    }

    # Print the status table (also used for --check and without a terminal).
    # On a terminal (or with report_cols set) the CONTAINERS column is
    # fitted to the width; in a pipe or file every container is listed.
    _dports_update_report() {
        local i w=5 numbered="${1:-false}" prefix col cols="" avail=0 list size
        for (( i = 0; i < ${#images[@]}; i++ )); do (( ${#img_label[i]} > w )) && w=${#img_label[i]}; done
        prefix=""; [[ "$numbered" == true ]] && prefix="     "
        if [[ -n "${report_cols:-}" ]]; then
            cols="$report_cols"
        elif [[ -t 1 ]]; then
            cols="${COLUMNS:-}"
            if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
                size=$(stty size </dev/tty 2>/dev/null); cols="${size#* }"
            fi
            [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]] || cols=$(tput cols 2>/dev/null)
            [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]] || cols=80
        fi
        # prefix + IMAGE + 2 + STATUS (8) + 1, and keep the last column free
        [[ -n "$cols" ]] && avail=$(( cols - 1 - ${#prefix} - w - 11 ))
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
            list="${users[i]}"
            (( avail >= 16 )) && _dports_fit_list list "$list" "$avail"
            printf "%s%-${w}s  ${col}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
                "$prefix" "${img_label[i]}" "${st[i]}" "$list"
        done
    }

    # _dports_pull_one I: pull images[I] and set ps[I]/pmsg[I]
    # (compares image IDs before/after instead of parsing pull output,
    # whose wording differs between image stores and Docker versions)
    _dports_pull_one() {
        local i="$1" before after output _dports_dk="${img_eng[$1]}"
        before=$(_dk image inspect --format '{{.Id}}' "${images[i]}" 2>/dev/null)
        if output=$(_dk pull "${images[i]}" 2>&1); then
            after=$(_dk image inspect --format '{{.Id}}' "${images[i]}" 2>/dev/null)
            if [[ "$before" != "$after" ]]; then ps[i]=updated pmsg[i]="Pulled a newer image"
            else ps[i]=unchanged pmsg[i]="Already up to date"; fi
        else
            ps[i]=failed pmsg[i]=$(grep . <<<"$output" | tail -1)
        fi
    }

    # Summary of what the run did (also printed after the full-screen flow)
    _dports_update_summary() {
        local i k w=5 n_up=0 n_un=0 n_fail=0 any=false col
        for (( i = 0; i < n; i++ )); do
            [[ -n "${ps[i]:-}" && "${ps[i]}" != queued ]] || continue
            any=true; (( ${#img_label[i]} > w )) && w=${#img_label[i]}
        done
        if [[ "$any" == true ]]; then
            printf "${C_BOLD}Pulled${C_RESET}\n"
            for (( i = 0; i < n; i++ )); do
                case "${ps[i]:-}" in
                    updated)    col="$C_GREEN";  (( n_up++ )) ;;
                    unchanged)  col="$C_DIM";    (( n_un++ )) ;;
                    failed)     col="$C_RED";    (( n_fail++ )) ;;
                    *)          continue ;;
                esac
                printf "  %-${w}s  ${col}%s${C_RESET}%s\n" "${img_label[i]}" "${ps[i]}" \
                    "$([[ "${ps[i]}" == failed ]] && printf ': %s' "${pmsg[i]}")"
            done
            printf "Updated %d · already current %d · failed %d\n" "$n_up" "$n_un" "$n_fail"
        fi
        any=false w=5
        for (( k = 0; k < ${#r_label[@]}; k++ )); do
            [[ -n "${r_state[k]:-}" && "${r_state[k]}" != queued && "${r_state[k]}" != outdated ]] || continue
            any=true; (( ${#r_label[k]} > w )) && w=${#r_label[k]}
        done
        if [[ "$any" == true ]]; then
            echo
            printf "${C_BOLD}Recreated${C_RESET}\n"
            for (( k = 0; k < ${#r_label[@]}; k++ )); do
                case "${r_state[k]:-}" in
                    recreated)  printf "  %-${w}s  ${C_GREEN}recreated${C_RESET}\n" "${r_label[k]}" ;;
                    failed)     printf "  %-${w}s  ${C_RED}failed${C_RESET}: %s\n" "${r_label[k]}" "${r_msg[k]}" ;;
                esac
            done
        fi
        _dports_outdated_report
    }

    # The interactive update: one full-screen flow from checking to
    # recreating. Prints the summary to keep in the scrollback.
    # Exit status: 0 done, 1 cancelled, 2 no usable terminal.
    # Always run it in a subshell ($(...)).
    _dports_update_tui() {
        _dports_tui_init || return 2
        local phase=check cur=0 top=0 page=1 msg="" i k rc res tmo
        local focus=list btn=0 tick=0 checked=0 pulling=-1 recreating=-1
        local rows cols tui_rule key
        local -a sel=() ps=() pmsg=() queue=() rq=() r_sel=() r_state=() r_msg=()
        local maxlen=5 n_upd=0 n_unknown=0
        for (( i = 0; i < n; i++ )); do
            (( ${#img_label[i]} > maxlen )) && maxlen=${#img_label[i]}
            st[i]="" detail[i]="Asking the registry..." sel[i]=0
        done
        _dports_tui_size
        _dports_check_start "$tui_tmp/check"

        # Status shown for image I in the current phase
        _dports_upd_status() {
            if [[ -n "${ps[$1]:-}" ]]; then printf '%s' "${ps[$1]}"
            elif [[ -z "${st[$1]}" ]]; then printf '%s' "checking"
            else printf '%s' "${st[$1]}"; fi
        }
        _dports_upd_color() {
            case "$1" in
                update|queued)          printf '%s' "$t_yellow" ;;
                current|updated|recreated) printf '%s' "$t_green" ;;
                local|pulling|recreating)  printf '%s' "$t_cyan" ;;
                unknown|failed)         printf '%s' "$t_red" ;;
                outdated)               printf '%s' "$t_yellow" ;;
                *)                      printf '%s' "$t_dim" ;;
            esac
        }

        _dports_upd_draw() {
            local frame="" line title right r j list_h name_w users_w mark s f1 f2 f3 n_sel=0 count
            local spin='|/-\'
            _dports_tui_size
            if [[ "$phase" == recreate ]]; then
                count=${#r_label[@]}
                list_h=$(( rows - 9 ))
            else
                count=$n
                list_h=$(( rows - 8 ))
            fi
            (( list_h < 1 )) && list_h=1
            page=$list_h
            _dports_tui_scroll "$count" "$list_h"

            case "$phase" in
                check)    right="checking ${spin:tick%4:1} $checked/$n" ;;
                select)   for (( r = 0; r < n; r++ )); do (( sel[r] )) && (( n_sel++ )); done
                          right="$n_upd update(s) · $n_sel selected · $(( cur + 1 ))/$n" ;;
                pull)     right="pulling ${spin:tick%4:1} $(( ${#queue[@]} + (pulling >= 0) )) left" ;;
                recreate) for (( r = 0; r < count; r++ )); do (( r_sel[r] )) && (( n_sel++ )); done
                          right="$count to recreate · $n_sel selected · $(( cur + 1 ))/$count" ;;
                finished) right="done" ;;
            esac
            _dports_fit title " dports update" $(( cols - ${#right} - 1 ))
            frame+="$t_bold$title$t_reset $right${e}[K"$'\n'
            frame+="$t_dim$tui_rule$t_reset${e}[K"$'\n'

            if [[ "$phase" == recreate ]]; then
                name_w=12
                for (( r = 0; r < count; r++ )); do (( ${#r_label[r]} > name_w )) && name_w=${#r_label[r]}; done
                (( name_w > cols - 40 )) && name_w=$(( cols - 40 ))
                (( name_w < 10 )) && name_w=10
                users_w=$(( cols - 6 - name_w - 2 - 10 - 2 ))
                _dports_fit f1 "SERVICE" "$name_w"; _dports_fit f2 "STATE" 10; _dports_fit f3 "CONTAINERS" "$users_w"
                frame+="$t_dim      $f1  $f2  $f3$t_reset${e}[K"$'\n'
                for (( r = 0; r < list_h; r++ )); do
                    j=$(( top + r )); line=""
                    if (( j < count )); then
                        s="${r_state[j]}"
                        if (( r_ok[j] )); then mark="[ ]"; (( r_sel[j] )) && mark="[x]"; else mark="   "; fi
                        [[ "$s" == recreating ]] && s="recreating"
                        _dports_fit f1 "${r_label[j]}" "$name_w"
                        _dports_fit f2 "$s" 10
                        _dports_fit f3 "${r_names[j]}" "$users_w"
                        if (( j == cur )) && [[ "$focus" == list ]]; then
                            line="$t_rev> $mark $f1  $f2  $f3$t_reset"
                        else
                            line="  $mark $f1  $(_dports_upd_color "$s")$f2$t_reset  $t_dim$f3$t_reset"
                        fi
                    fi
                    frame+="$line${e}[K"$'\n'
                done
            else
                name_w=$(( cols - 6 - 2 - 10 - 2 - 12 ))
                (( name_w > maxlen )) && name_w=$maxlen
                (( name_w < 10 )) && name_w=10
                users_w=$(( cols - 6 - name_w - 2 - 10 - 2 ))
                _dports_fit f1 "IMAGE" "$name_w"; _dports_fit f2 "STATUS" 10; _dports_fit f3 "CONTAINERS" "$users_w"
                frame+="$t_dim      $f1  $f2  $f3$t_reset${e}[K"$'\n'
                for (( r = 0; r < list_h; r++ )); do
                    j=$(( top + r )); line=""
                    if (( j < n )); then
                        s=$(_dports_upd_status "$j")
                        [[ "$s" == checking || "$s" == pulling ]] && s="$s ${spin:(tick+j)%4:1}"
                        mark="[ ]"; (( sel[j] )) && mark="[x]"
                        [[ "$phase" == check ]] && mark="   "
                        _dports_fit f1 "${img_label[j]}" "$name_w"
                        _dports_fit f2 "$s" 10
                        _dports_fit f3 "${users[j]}" "$users_w"
                        if (( j == cur )) && [[ "$phase" == select || "$phase" == finished ]]; then
                            line="$t_rev> $mark $f1  $f2  $f3$t_reset"
                        else
                            line="  $mark $f1  $(_dports_upd_color "${s%% *}")$f2$t_reset  $t_dim$f3$t_reset"
                        fi
                    fi
                    frame+="$line${e}[K"$'\n'
                done
            fi

            s=""
            (( top > 0 )) && s+="↑ "
            (( top + list_h < count )) && s+="↓ more"
            _dports_tui_line line "$t_dim" "$s"; frame+="$line"$'\n'
            frame+="$t_dim$tui_rule$t_reset${e}[K"$'\n'

            # Detail lines for the row under the cursor
            if [[ "$phase" == recreate ]]; then
                if (( count == 0 )); then
                    _dports_tui_line line "" " Nothing to recreate"; frame+="$line"$'\n'
                    _dports_tui_line line "" ""; frame+="$line"$'\n'
                else
                    if [[ -n "${r_msg[cur]:-}" ]]; then
                        _dports_tui_line line "$(_dports_upd_color "${r_state[cur]}")" " ${r_label[cur]}: ${r_msg[cur]}"
                    elif (( r_ok[cur] )); then
                        _dports_tui_line line "" " $(_dports_recreate_cmd "$cur")"
                    else
                        _dports_tui_line line "$t_yellow" " $(_dports_recreate_cmd "$cur")"
                    fi
                    frame+="$line"$'\n'
                    _dports_tui_line line "" " Image: ${r_image[cur]}   Containers: ${r_names[cur]}"
                    frame+="$line"$'\n'
                fi
                # Buttons
                local -a labels=("Recreate this" "Recreate selected ($n_sel)" "Recreate all" "Done")
                s=" "
                for (( r = 0; r < 4; r++ )); do
                    if [[ "$focus" == buttons ]] && (( r == btn )); then
                        s+="${t_rev}[ ${labels[r]} ]$t_reset  "
                    else
                        s+="${t_bold}[ ${labels[r]} ]$t_reset  "
                    fi
                done
                frame+="$s${e}[K"$'\n'
            else
                s=$(_dports_upd_status "$cur")
                if [[ -n "${pmsg[cur]:-}" ]]; then
                    _dports_tui_line line "$(_dports_upd_color "${s%% *}")" " ${img_label[cur]}: ${pmsg[cur]}"
                else
                    _dports_tui_line line "$(_dports_upd_color "${s%% *}")" " ${img_label[cur]}: ${detail[cur]}"
                fi
                frame+="$line"$'\n'
                _dports_tui_line line "" " Used by: ${users[cur]:--}"; frame+="$line"$'\n'
            fi

            if [[ -n "$msg" ]]; then
                _dports_tui_line line "$t_yellow" " $msg"
            else
                case "$phase" in
                    check)    s=" Checking the registries...  q quit" ;;
                    select)   s=" ↑↓ move  Space toggle  u updates  a all  n none  Enter pull"
                              (( ${#r_label[@]} )) && s+="  r recreate (${#r_label[@]})"
                              s+="  q quit" ;;
                    pull)     s=" Pulling the selected images..." ;;
                    recreate) s=" ↑↓ move  Space select  Enter recreate this  s selected  A all  Tab buttons  q done" ;;
                    finished) s=" Enter or q: exit" ;;
                esac
                _dports_tui_line line "$t_dim" "$s"
            fi
            frame+="${line%"${e}[K"}"
            printf '%s' "${e}[H$frame${e}[K${e}[J" >&3
        }

        # Queue recreate item K unless it is manual, busy or done
        _dports_upd_queue_r() {
            local k="$1" q
            (( r_ok[k] )) || { msg="${r_label[k]} is not managed by Compose: recreate it by hand"; return 1; }
            case "${r_state[k]}" in
                queued|recreating) return 1 ;;
                recreated) msg="${r_label[k]} is already recreated"; return 1 ;;
            esac
            for q in "${rq[@]}"; do [[ "$q" == "$k" ]] && return 1; done
            rq+=("$k"); r_state[k]=queued r_msg[k]=""
        }

        _dports_upd_enter_recreate() {
            local k
            _dports_outdated
            r_sel=() r_state=() r_msg=()
            for (( k = 0; k < ${#r_label[@]}; k++ )); do
                r_sel[k]=0 r_state[k]=outdated r_msg[k]=""
                (( r_ok[k] )) || r_state[k]=manual
            done
            phase=recreate cur=0 top=0 focus=list btn=0
            if [[ "${auto_recreate:-false}" == true ]]; then
                for (( k = 0; k < ${#r_label[@]}; k++ )); do (( r_ok[k] )) && _dports_upd_queue_r "$k"; done
            fi
        }

        _dports_upd_finish() {
            report_cols=$(( cols + 1 ))
            _dports_update_summary
            exit 0
        }

        while true; do
            (( tick++ ))
            # ── advance the background work ──
            case "$phase" in
                check)
                    if _dports_check_poll "$tui_tmp/check"; then
                        n_upd=0 n_unknown=0
                        for (( i = 0; i < n; i++ )); do
                            [[ "${st[i]}" == update ]] && { (( n_upd++ )); sel[i]=1; }
                            [[ "${st[i]}" == unknown ]] && (( n_unknown++ ))
                        done
                        _dports_outdated
                        if (( n_upd == 0 && n_unknown == 0 && ${#r_label[@]} == 0 )); then
                            report_cols=$(( cols + 1 ))
                            _dports_update_report
                            echo
                            echo "All images are up to date."
                            exit 0
                        fi
                        phase=select cur=0 top=0
                        if (( n_upd == 0 )); then
                            msg="No updates found."
                            (( ${#r_label[@]} )) && msg+=" ${#r_label[@]} container(s) run an older image: press r to recreate"
                        fi
                    fi ;;
                pull)
                    if (( pulling >= 0 )) && [[ -e "$tui_tmp/pull.done" ]]; then
                        IFS=$'\t' read -r "ps[pulling]" "pmsg[pulling]" < "$tui_tmp/pull.done"
                        rm -f "$tui_tmp/pull.done"
                        pulling=-1
                    elif (( pulling >= 0 )); then
                        res=$(grep . "$tui_tmp/pull.log" 2>/dev/null | tail -1)
                        [[ -n "$res" ]] && _dports_tui_clean "pmsg[pulling]" "$res"
                    fi
                    if (( pulling < 0 )); then
                        if (( ${#queue[@]} )); then
                            pulling=${queue[0]}; queue=("${queue[@]:1}")
                            ps[pulling]=pulling pmsg[pulling]="Starting..."
                            cur=$pulling
                            (
                                _dports_dk="${img_eng[pulling]}"
                                before=$(_dk image inspect --format '{{.Id}}' "${images[pulling]}" 2>/dev/null)
                                if _dk pull "${images[pulling]}" > "$tui_tmp/pull.log" 2>&1; then
                                    after=$(_dk image inspect --format '{{.Id}}' "${images[pulling]}" 2>/dev/null)
                                    if [[ "$before" != "$after" ]]; then
                                        printf 'updated\tPulled a newer image\n'
                                    else
                                        printf 'unchanged\tAlready up to date\n'
                                    fi > "$tui_tmp/pull.res"
                                else
                                    printf 'failed\t%s\n' "$(grep . "$tui_tmp/pull.log" | tail -1 | tr -d '\r\t')" > "$tui_tmp/pull.res"
                                fi
                                mv -f "$tui_tmp/pull.res" "$tui_tmp/pull.done"
                            ) &
                        else
                            _dports_upd_enter_recreate
                            if (( ${#r_label[@]} == 0 )); then
                                phase=finished
                                msg="Nothing to recreate. Enter or q: exit"
                            fi
                        fi
                    fi ;;
                recreate)
                    if (( recreating >= 0 )) && [[ -e "$tui_tmp/up.done" ]]; then
                        rc=$(cat "$tui_tmp/up.done"); rm -f "$tui_tmp/up.done"
                        res=$(grep . "$tui_tmp/up.log" 2>/dev/null | tail -1)
                        if [[ "$rc" == 0 ]]; then
                            r_state[recreating]=recreated r_msg[recreating]=""
                        else
                            r_state[recreating]=failed
                            _dports_tui_clean "r_msg[recreating]" "${res:-recreating failed}"
                        fi
                        recreating=-1
                    elif (( recreating >= 0 )); then
                        res=$(grep . "$tui_tmp/up.log" 2>/dev/null | tail -1)
                        [[ -n "$res" ]] && _dports_tui_clean "r_msg[recreating]" "$res"
                    fi
                    if (( recreating < 0 && ${#rq[@]} )); then
                        recreating=${rq[0]}; rq=("${rq[@]:1}")
                        r_state[recreating]=recreating r_msg[recreating]="Starting..."
                        (
                            _dports_compose_up "$recreating" > "$tui_tmp/up.log" 2>&1
                            echo $? > "$tui_tmp/up.res"
                            mv -f "$tui_tmp/up.res" "$tui_tmp/up.done"
                        ) &
                    fi ;;
            esac

            _dports_upd_draw
            tmo=1
            [[ "$phase" == check || "$phase" == pull ]] && tmo=0.2
            (( recreating >= 0 || ${#rq[@]} )) && tmo=0.2
            _dports_tui_readkey "$tmo"; rc=$?
            (( rc == 2 )) && exit 1
            (( rc == 1 )) && continue
            msg=""

            case "$phase" in
                check)
                    case "$key" in
                        q|Q|esc) echo "Cancelled."; exit 1 ;;
                    esac ;;
                select)
                    _dports_tui_move "$n" "$page" && continue
                    case "$key" in
                        space|x)    sel[cur]=$(( 1 - sel[cur] )) ;;
                        u)          for (( i = 0; i < n; i++ )); do
                                        if [[ "${st[i]}" == update ]]; then sel[i]=1; else sel[i]=0; fi
                                    done ;;
                        a)          for (( i = 0; i < n; i++ )); do sel[i]=1; done ;;
                        n)          for (( i = 0; i < n; i++ )); do sel[i]=0; done ;;
                        r)          if (( ${#r_label[@]} )); then _dports_upd_enter_recreate
                                    else msg="No container runs an older image than its tag"; fi ;;
                        enter)      queue=()
                                    for (( i = 0; i < n; i++ )); do
                                        (( sel[i] )) && { queue+=("$i"); ps[i]=queued; }
                                    done
                                    if (( ${#queue[@]} )); then
                                        phase=pull
                                    elif (( ${#r_label[@]} )); then
                                        _dports_upd_enter_recreate
                                    else
                                        msg="Nothing selected: Space selects an image, q quits"
                                    fi ;;
                        q|Q|esc|$'\004') echo "Cancelled."; exit 1 ;;
                    esac ;;
                pull)
                    case "$key" in
                        q|Q|esc) msg="Pulling... wait for it to finish (Ctrl+C stops dports, not the pull)" ;;
                    esac ;;
                recreate)
                    if [[ "$focus" == list ]]; then
                        _dports_tui_move "${#r_label[@]}" "$page" && continue
                    fi
                    case "$key" in
                        tab)        if [[ "$focus" == list ]]; then focus=buttons; else focus=list; fi ;;
                        left)       [[ "$focus" == buttons ]] && (( btn > 0 )) && (( btn-- )) ;;
                        right)      [[ "$focus" == buttons ]] && (( btn < 3 )) && (( btn++ )) ;;
                        space|x)    if (( ${#r_label[@]} )) && (( r_ok[cur] )); then r_sel[cur]=$(( 1 - r_sel[cur] ))
                                    elif (( ${#r_label[@]} )); then msg="${r_label[cur]} is not managed by Compose: recreate it by hand"; fi ;;
                        s|S)        key=btn1 ;;
                        A)          key=btn2 ;;
                        enter)      if [[ "$focus" == list ]]; then key=btn0; else key="btn$btn"; fi ;;
                        q|Q|esc|d)  key=btn3 ;;
                    esac
                    case "$key" in
                        btn0)   (( ${#r_label[@]} )) && _dports_upd_queue_r "$cur" ;;
                        btn1)   k=0
                                for (( i = 0; i < ${#r_label[@]}; i++ )); do
                                    (( r_sel[i] )) && { _dports_upd_queue_r "$i"; r_sel[i]=0; (( k++ )); }
                                done
                                (( k )) || msg="Nothing selected: Space selects a service" ;;
                        btn2)   for (( i = 0; i < ${#r_label[@]}; i++ )); do
                                    (( r_ok[i] )) && _dports_upd_queue_r "$i"
                                done ;;
                        btn3)   if (( recreating >= 0 || ${#rq[@]} )); then
                                    msg="Recreating... wait for it to finish"
                                else
                                    _dports_upd_finish
                                fi ;;
                    esac ;;
                finished)
                    case "$key" in
                        enter|q|Q|esc) _dports_upd_finish ;;
                        *) _dports_tui_move "$n" "$page" ;;
                    esac ;;
            esac
        done
    }

    # Check images, let the user pick, pull the picks, recreate containers.
    _dports_update() {
        local mode=interactive arg auto_recreate=false want_engine=false
        for arg in "$@"; do
            if [[ "$want_engine" == true ]]; then engine_opt="$arg" want_engine=false; continue; fi
            case "$arg" in
                --check)        mode=check ;;
                -y|--yes)       mode=yes ;;
                --recreate)     auto_recreate=true ;;
                --engine)       want_engine=true ;;
                --engine=*)     engine_opt="${arg#*=}" ;;
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
        if [[ "$mode" == check && "$auto_recreate" == true ]]; then
            echo "Error: --recreate cannot be combined with --check" >&2; return 1
        fi

        _dports_config_load
        [[ -z "$DPORTS_TIMEOUT" && -n "$cfg_timeout" ]] && DPORTS_TIMEOUT="$cfg_timeout"
        _dports_engines_resolve || return 1
        if (( ${#dk_engines[@]} == 0 )); then
            echo "dports update works with Docker and Podman. Incus and LXD instances are not created" >&2
            echo "from registry images, so there is nothing to check for them." >&2
            return 0
        fi
        if (( ${#dk_engines[@]} == 1 )) && ! command -v "${dk_engines[0]}" &>/dev/null; then
            echo "Error: ${dk_engines[0]} is not installed or not in PATH" >&2; return 1
        fi

        # Running containers of every docker-family engine, by the reference
        # each was created from (`docker ps` shows a bare image ID once the
        # tag has moved on)
        local -a c_img=() c_name=() c_eng=() ok_engines=()
        local a b e container_ids platform=""
        for e in "${dk_engines[@]}"; do
            _dports_dk=$e
            if [[ -z "$platform" ]] && ! _dports_platform; then
                (( ${#dk_engines[@]} > 1 )) && echo "Note: cannot reach $e; it is left out." >&2
                continue
            fi
            ok_engines+=("$e")
            container_ids=$(_dk ps -q 2>/dev/null)
            [[ -n "$container_ids" ]] || continue
            # shellcheck disable=SC2086
            while IFS=$'\t' read -r a b; do
                [[ -n "$a" ]] || continue
                c_img+=("$a"); c_name+=("${b#/}"); c_eng+=("$e")
            done < <(_dk inspect --format '{{.Config.Image}}{{"\t"}}{{.Name}}' $container_ids 2>/dev/null)
        done
        if (( ${#ok_engines[@]} == 0 )); then
            if [[ "${dk_engines[0]}" == docker ]]; then
                echo "Error: Cannot connect to Docker daemon." >&2
            else
                echo "Error: Cannot connect to ${dk_engines[*]}." >&2
            fi
            return 1
        fi
        dk_engines=("${ok_engines[@]}")
        if [[ ${#c_img[@]} -eq 0 ]]; then
            echo "No running containers found." >&2; return 0
        fi

        local -a images=() img_eng=() img_label=() st=() detail=() users=() ps=() pmsg=()
        local -a r_label=() r_names=() r_image=() r_dir=() r_proj=() r_files=() r_svc=() r_ok=() r_state=() r_msg=()
        local -a r_eng=() r_kind=() r_unit=()
        local -A by_img=()
        local i k n checked=0 report_cols="" key
        for (( k = 0; k < ${#c_img[@]}; k++ )); do
            key="${c_eng[k]}"$'\t'"${c_img[k]}"
            by_img["$key"]+="${by_img["$key"]:+, }${c_name[k]}"
        done
        # One entry per (engine, image); the engine is shown when several are in use
        while IFS=$'\t' read -r a b; do
            [[ -n "$b" ]] || continue
            img_eng+=("$a"); images+=("$b")
            if (( ${#dk_engines[@]} > 1 )); then img_label+=("$b [$a]"); else img_label+=("$b"); fi
        done < <(printf '%s\n' "${!by_img[@]}" | sort -t$'\t' -k2,2 -k1,1)
        n=${#images[@]}
        for (( i = 0; i < n; i++ )); do users[i]="${by_img["${img_eng[i]}"$'\t'"${images[i]}"]}"; st[i]=""; done

        # ── Interactive: everything happens in the full-screen flow ──────────
        if [[ "$mode" == interactive && -t 0 && -t 1 ]]; then
            local out rc
            out=$(_dports_update_tui); rc=$?
            if (( rc != 2 )); then
                [[ -n "$out" ]] && printf '%s\n' "$out"
                (( rc == 1 )) && return 0
                return "$rc"
            fi
            # No full-screen terminal (TERM=dumb): numbered prompt below
            for (( i = 0; i < n; i++ )); do st[i]=""; done
        fi

        # ── Check phase (text) ───────────────────────────────────────────────
        local tmpdir
        tmpdir=$(mktemp -d) || return 1
        _dports_check_start "$tmpdir"
        until _dports_check_poll "$tmpdir"; do
            [[ -t 2 ]] && printf '\r\033[K  Checking %d image(s) for updates... %d/%d' "$n" "$checked" "$n" >&2
            sleep 0.1
        done
        [[ -t 2 ]] && printf '\r\033[K' >&2
        rm -rf "$tmpdir"

        local n_upd=0
        for (( i = 0; i < n; i++ )); do [[ "${st[i]}" == update ]] && (( n_upd++ )); done

        # ── Selection ────────────────────────────────────────────────────────
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
                _dports_outdated
                _dports_outdated_report
                return 0 ;;
            yes)
                for (( i = 0; i < n; i++ )); do [[ "${st[i]}" == update ]] && chosen+=("$i"); done
                _dports_update_report
                echo ;;
            interactive)
                # Numbered prompt (no full-screen terminal)
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
                if [[ ${#chosen[@]} -eq 0 ]]; then echo "No images selected."; return 0; fi ;;
        esac

        # ── Pull phase (text) ────────────────────────────────────────────────
        local label n_fail=0
        if (( ${#chosen[@]} )); then
            printf "${C_BOLD}Pulling %d image(s)${C_RESET}\n" "${#chosen[@]}"
            for (( k = 0; k < ${#chosen[@]}; k++ )); do
                i=${chosen[k]}
                label="[$(( k + 1 ))/${#chosen[@]}] ${img_label[i]}"
                [[ -t 1 ]] && printf "  ${C_CYAN}%s${C_RESET} ..." "$label"
                _dports_pull_one "$i"
                [[ -t 1 ]] && printf '\r\033[K'
                case "${ps[i]}" in
                    updated)    printf "  ${C_CYAN}%s${C_RESET}  ${C_GREEN}updated${C_RESET}\n" "$label" ;;
                    unchanged)  printf "  ${C_CYAN}%s${C_RESET}  ${C_DIM}already up to date${C_RESET}\n" "$label" ;;
                    *)          printf "  ${C_CYAN}%s${C_RESET}  ${C_RED}failed${C_RESET}\n" "$label"
                                printf '      %s\n' "${pmsg[i]}"
                                (( n_fail++ )) ;;
                esac
            done
        else
            echo "All images are up to date."
        fi

        # ── Recreate (text) ──────────────────────────────────────────────────
        _dports_outdated
        if [[ "$auto_recreate" == true ]]; then
            local out
            for (( k = 0; k < ${#r_label[@]}; k++ )); do
                (( r_ok[k] )) || continue
                [[ -t 1 ]] && printf "  ${C_CYAN}%s${C_RESET} ..." "${r_label[k]}"
                if out=$(_dports_compose_up "$k"); then
                    r_state[k]=recreated
                    [[ -t 1 ]] && printf '\r\033[K'
                    printf "  ${C_CYAN}%s${C_RESET}  ${C_GREEN}recreated${C_RESET}\n" "${r_label[k]}"
                else
                    r_state[k]=failed r_msg[k]=$(grep . <<<"$out" | tail -1)
                    [[ -t 1 ]] && printf '\r\033[K'
                    printf "  ${C_CYAN}%s${C_RESET}  ${C_RED}failed${C_RESET}\n      %s\n" "${r_label[k]}" "${r_msg[k]}"
                    (( n_fail++ ))
                fi
            done
        fi
        _dports_outdated_report
        (( n_fail == 0 ))
    }

    # ── Port listing helpers ───────────────────────────────────────────────────

    # Print "{{.Ports}}<TAB>NAME<TAB>IMAGE" for the running containers of the
    # current docker-family engine, plus the configured bindings of stopped
    # ones with -a. Returns 1 when the engine cannot be reached.
    _dports_port_data() {
        local data stopped_ids stopped fmt
        local -a states=(--filter status=created --filter status=exited --filter status=dead)
        fmt='{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{if .HostPort}}{{.HostIp}}:{{.HostPort}}->{{$p}}, {{end}}{{end}}{{end}}{{"\t"}}{{.Name}}{{"\t"}}{{.Config.Image}}'
        if [[ "$_dports_dk" == podman ]]; then
            # Podman names the field HostIP and has no "dead" state
            fmt="${fmt//.HostIp/.HostIP}"
            states=(--filter status=created --filter status=exited --filter status=stopped)
        fi
        data=$(_dk ps --format "{{.Ports}}\t{{.Names}}\t{{.Image}}" 2>/dev/null) || return 1
        # Stopped containers have an empty Ports column in `docker ps -a`,
        # so read their configured bindings from `docker inspect` instead.
        if [[ "$show_all" == true ]]; then
            stopped_ids=$(_dk ps -aq "${states[@]}" 2>/dev/null)
            if [[ -n "$stopped_ids" ]]; then
                # shellcheck disable=SC2086
                stopped=$(_dk inspect --format "$fmt" $stopped_ids 2>/dev/null \
                    | awk -F'\t' 'BEGIN { OFS = "\t" } { sub(/^\//, "", $2); print }')
                data=$(printf '%s\n%s' "$data" "$stopped")
            fi
        fi
        printf '%s\n' "$data" | sed '/^$/d'
    }

    # _dports_port_rows DATA ENGINE: one line per published port,
    # PORT<TAB>NAME<TAB>INTERNAL<TAB>IMAGE<TAB>ENGINE
    _dports_port_rows() {
        [[ -n "$1" ]] || return 0
        awk -F"\t" -v engine="$2" '
        {
            # Split multiple port mappings: [host:]port->container_port/protocol
            n = split($1, ports, ", ")
            for (i = 1; i <= n; i++) {
                if (ports[i] !~ /->/) continue
                split(ports[i], mapping, "->")
                # Host port without the address (IPv4/IPv6: 0.0.0.0:8080, :::8080)
                host_port = mapping[1]
                gsub(/^\[?[0-9a-fA-F.:]*\]?:/, "", host_port)
                printf "%s\t%s\t%s\t%s\t%s\n", host_port, $2, mapping[2], $3, engine
            }
        }' <<<"$1"
    }

    # Published ports of every active engine, filtered and sorted:
    # PORT<TAB>NAME<TAB>INTERNAL<TAB>IMAGE<TAB>ENGINE.
    # Returns 1 when no engine could be reached.
    _dports_all_rows() {
        local e data ok=0 out=""
        engines_failed=()
        for e in "${engines[@]}"; do
            case "$e" in
                docker|podman)
                    _dports_dk=$e
                    if data=$(_dports_port_data); then
                        ok=1; out+=$(_dports_port_rows "$data" "$e")$'\n'
                    else
                        _dports_engine_warn "$e"
                    fi ;;
                incus|lxd)
                    if data=$(_dports_ic_rows "$e"); then
                        ok=1; out+="$data"$'\n'
                    else
                        _dports_engine_warn "$e"
                    fi ;;
            esac
        done
        (( ok )) || return 1
        awk -F'\t' \
            -v filter_port="$filter_port" \
            -v filter_name="$filter_name" \
            -v filter_image="$filter_image" '
            NF < 2 { next }
            filter_name != "" && index(tolower($2), tolower(filter_name)) == 0 { next }
            filter_image != "" && index(tolower($4), tolower(filter_image)) == 0 { next }
            filter_port != "" && $1 != filter_port { next }
            { print }' <<<"$out" | sort -t$'\t' -k1 -V | uniq
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
        mapfile -t argv < <(_dk inspect --format '{{range .Args}}{{.}}{{"\n"}}{{end}}' "$cf" 2>/dev/null)
        env=$(_dk inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$cf" 2>/dev/null)
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
        netmode=$(_dk inspect --format '{{.HostConfig.NetworkMode}}' "$cf" 2>/dev/null)

        # 1. Metrics server
        if [[ "$direct" == true ]]; then
            local hosts ports host port json quick found
            if [[ "$netmode" == host ]]; then
                hosts="127.0.0.1"
            else
                hosts=$(_dk inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cf" 2>/dev/null)
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
                workdir=$(_dk inspect --format '{{.Config.WorkingDir}}' "$cf" 2>/dev/null)
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
            yaml=$(_dk cp "$cf:$p" - 2>/dev/null | tar -xOf - 2>/dev/null) && [[ -n "$yaml" ]] && break
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

    # Print one line per Cloudflare Tunnel route:
    # HOSTNAME PATH NAME IMAGE PORT PROTOCOL SERVICE TUNNEL (tab-separated).
    # Returns 3 when no cloudflared container runs.
    # Each ingress rule is matched to the container its service points at,
    # by container name, compose service, network alias, hostname or IP on
    # a network shared with cloudflared.
    _dports_tunnel_rows() {
        local stream="" ids cf cfs="" rules cf_id cf_mode cf_nets e direct info endpoint
        local -a cf_list=()

        # Identity of every running container (I), containers sharing
        # another container's network namespace (S) and published ports (P),
        # for every engine; cloudflared runs under Docker or Podman.
        for e in "${dk_engines[@]}"; do
            _dports_dk=$e
            ids=$(_dk ps -q 2>/dev/null)
            [[ -n "$ids" ]] || continue
            cfs=$(_dk ps --no-trunc --format '{{.Names}}\t{{.Image}}\t{{.Command}}' 2>/dev/null \
                | awk -F'\t' 'tolower($2) ~ /cloudflared/ || $3 ~ /cloudflared/ { print $1 }')
            while IFS= read -r cf; do [[ -n "$cf" ]] && cf_list+=("$e"$'\t'"$cf"); done <<<"$cfs"
            # shellcheck disable=SC2086
            stream+=$'\n'$(_dk inspect --format '{{$n := .Name}}{{$i := .Config.Image}}{{if eq (printf "%.10s" .HostConfig.NetworkMode) "container:"}}S{{"\t"}}{{.HostConfig.NetworkMode}}{{"\t"}}{{$n}}{{"\t"}}{{$i}}{{"\n"}}{{end}}{{$h := .Config.Hostname}}{{$s := index .Config.Labels "com.docker.compose.service"}}{{range $net, $c := .NetworkSettings.Networks}}I{{"\t"}}{{$n}}{{"\t"}}{{$i}}{{"\t"}}{{$net}}{{"\t"}}{{$c.IPAddress}}{{"\t"}}{{$n}} {{$h}} {{$s}} {{join $c.Aliases " "}}{{"\n"}}{{end}}' $ids 2>/dev/null \
                | awk -F'\t' -v engine="$e" 'BEGIN { OFS = "\t" }
                    $1 == "S" { sub(/^\//, "", $3) }
                    $1 == "I" { sub(/^\//, "", $2); sub(/^\//, "", $6) }
                    NF { print $0, engine }')
            stream+=$'\n'$(_dk ps --format '{{.Ports}}\t{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' -v engine="$e" '{
                n = split($1, ports, ", ")
                for (i = 1; i <= n; i++) if (ports[i] ~ /->/) {
                    split(ports[i], m, "->"); hp = m[1]
                    gsub(/^\[?[0-9a-fA-F.:]*\]?:/, "", hp)
                    printf "P\t%s\t%s\t%s\t%s\n", hp, $2, $3, engine
                }
            }')
        done
        (( ${#cf_list[@]} )) || return 3

        # Incus/LXD instances: tunnels reach them by address or published port
        for e in "${ic_engines[@]}"; do
            stream+=$'\n'$(_dports_ic_records "$e" true 2>/dev/null | awk -F'\t' -v engine="$e" '
                function disp(n, p) { return (p == "default" || p == "") ? n : p "/" n }
                $1 == "X" { img[$2 SUBSEP $3] = ($5 == "" ? "-" : $5) }
                $1 == "A" { a[++na] = $0 }
                END { for (i = 1; i <= na; i++) { split(a[i], f, "\t"); k = f[2] SUBSEP f[3]
                        printf "I\t%s\t%s\t%s\t%s\t%s\t%s\n", disp(f[2], f[3]), img[k], engine ":" f[5], f[4], f[2], engine } }')
            stream+=$'\n'$(show_all=true _dports_ic_rows "$e" 2>/dev/null | awk -F'\t' '{ printf "P\t%s\t%s\t%s\t%s\n", $1, $2, $4, $5 }')
        done

        for cf in "${cf_list[@]}"; do
            e="${cf%%$'\t'*}" cf="${cf#*$'\t'}"
            _dports_dk=$e
            # Can the host reach container IPs? Not on Docker Desktop, rootless
            # Docker or Podman, or a remote daemon.
            direct=false
            if [[ "$(uname -s)" == Linux ]]; then
                if [[ "$e" == podman ]]; then
                    (( EUID == 0 )) && direct=true
                else
                    endpoint="${DOCKER_HOST:-$(_dk context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)}"
                    info=$(_dk info --format '{{.OperatingSystem}} {{.SecurityOptions}}' 2>/dev/null)
                    if [[ ( -z "$endpoint" || "$endpoint" == unix://* ) \
                        && "$info" != *"Docker Desktop"* && "$info" != *rootless* ]]; then
                        direct=true
                    fi
                fi
            fi
            if ! rules=$(_dports_tunnel_ingress "$cf" "$direct"); then
                echo "Note: cannot read the ingress rules of '$cf'" \
                    "(no config file in the container, and its metrics server is not reachable from this host)." >&2
                continue
            fi
            read -r cf_id cf_mode cf_nets < <(_dk inspect --format \
                '{{.Id}} {{.HostConfig.NetworkMode}} {{range $net, $c := .NetworkSettings.Networks}}{{$net}},{{end}}' "$cf" 2>/dev/null)
            if [[ "$cf_mode" == container:* ]]; then
                cf_mode="container:$(_dk inspect --format '{{.Name}}' "${cf_mode#container:}" 2>/dev/null)"
                cf_mode="container:${cf_mode#container:/}"
            fi
            stream+=$'\n'$(awk -F'\t' -v cf="$cf" -v id="$cf_id" -v mode="$cf_mode" -v nets="$cf_nets" \
                '{ printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cf, id, mode, nets, $1, $2, $3 }' <<<"$rules")
        done

        printf '%s\n' "$stream" | awk -F'\t' \
            -v filter_port="$filter_port" \
            -v filter_name="$filter_name" \
            -v filter_image="$filter_image" '
            $1 == "I" {
                split($6, names, " ")
                for (k in names) if (names[k] != "") {
                    byname[$4 SUBSEP names[k]] = $2; image[$2] = $3
                }
                if ($5 != "") byip[$5] = $2
                image[$2] = $3; eng[$2] = $7
                next
            }
            $1 == "S" { shared[$2] = $3; image[$3] = $4; eng[$3] = $5; next }
            $1 == "P" { if (!($2 in published)) { published[$2] = $3; image[$3] = $4; eng[$3] = $5 }; next }
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
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                    (hostname == "" ? "*" : hostname), path, name, img, port, proto, svc, cf, \
                    ((name in eng) ? eng[name] : "")
            }' | sort -t$'\t' -k1,1 -k2,2 | uniq
    }

    # Print the Cloudflare Tunnel routes table (or JSON / hostnames)
    _dports_tunnel_section() {
        local results rc
        results=$(_dports_tunnel_rows); rc=$?

        if [[ -z "$results" ]]; then
            if [[ "$json_output" == true ]]; then
                echo "[]"
            elif (( rc == 3 )); then
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
            local hostname path name img port proto svc tunnel target _eng
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
            while IFS=$'\037' read -r hostname path name img port proto svc tunnel _eng; do
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

    # ── Interactive browser (EXPERIMENTAL, dports -I) ──────────────────────────

    # Rows: KIND<TAB>KEY<TAB>NAME<TAB>TARGET<TAB>IMAGE<TAB>SERVICE<TAB>TUNNEL<TAB>ENGINE
    _dports_browse_rows() {
        local rows
        rows=$(_dports_all_rows 2>/dev/null) || return 1
        # ("-" fills the tunnel-only fields: read -a with a tab IFS would
        # collapse empty ones and shift the engine)
        [[ -n "$rows" ]] && awk -F'\t' '{ printf "port\t%s\t%s\t%s\t%s\t-\t-\t%s\n", $1, $2, $3, $4, $5 }' <<<"$rows"
        if [[ "$show_tunnel" == true ]]; then
            _dports_tunnel_rows 2>/dev/null | awk -F'\t' '{
                key = $1; if ($2 != "") key = key " " $2
                printf "tunnel\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", key, $3, ($5 != "" ? $5 "/" : "") $6, $4, $7, $8, $9
            }'
        fi
        return 0
    }

    # Full-screen list of ports (and tunnel routes with -t): search, details,
    # logs, restart, shell, live refresh. Run it in a subshell.
    _dports_browse() {
        if ! _dports_tui_init; then
            echo "Error: dports -I needs an interactive terminal" >&2
            return 1
        fi
        local rows cols tui_rule key rc i j cur=0 top=0 page=1 msg="" tick=0
        local query="" typing=false interval="${DPORTS_REFRESH:-${cfg_refresh:-5}}" loaded_at=-1000 loading=false
        local confirm="" confirm_eng="" busy="" sel_id="" loaded=false ic_name=""
        local -a ic_args=()
        local -a all=() shown=()
        local -A dcache=()
        [[ "$interval" =~ ^[0-9]+$ ]] || interval=5

        _dports_browse_load() {
            loading=true loaded_at=$SECONDS
            (
                _dports_browse_rows > "$tui_tmp/rows.tmp" 2>/dev/null
                mv -f "$tui_tmp/rows.tmp" "$tui_tmp/rows"
            ) &
        }

        _dports_browse_filter() {
            local q="${query,,}" l
            shown=()
            for (( i = 0; i < ${#all[@]}; i++ )); do
                l="${all[i],,}"
                [[ -z "$q" || "$l" == *"$q"* ]] && shown+=("$i")
            done
        }

        # Keep the cursor on the same row (kind, key, name) after a reload
        _dports_browse_keep() {
            local id
            for (( j = 0; j < ${#shown[@]}; j++ )); do
                IFS=$'\t' read -r -a f <<<"${all[shown[j]]}"
                id="${f[0]}|${f[1]}|${f[2]}"
                [[ "$id" == "$sel_id" ]] && { cur=$j; return; }
            done
        }

        # _dports_ic_target NAME: the instance and --project arguments of an
        # Incus/LXD row name ("project/name" outside the default project)
        _dports_ic_target() {
            ic_args=()
            if [[ "$1" == */* ]]; then ic_name="${1#*/}"; ic_args=(--project "${1%%/*}")
            else ic_name="$1"; fi
        }

        # _dports_browse_ic_detail NAME ENGINE: d1 d2 d3 of an Incus/LXD instance
        _dports_browse_ic_detail() {
            local name="$1" e="$2" cli recs proj=default
            local -a ic_args=()
            _dports_ic_target "$name"
            [[ "$name" == */* ]] && proj="${name%%/*}"
            cli=$(_dports_engine_cli "$e")
            if [[ -z "${dcache[$e|$name]+x}" ]]; then
                # (a single instance comes with its state: one call)
                dcache[$e|$name]=$(_dports_ic_query "$cli" "/1.0/instances/$ic_name?recursion=1&project=$proj" instance 2>/dev/null)
            fi
            recs="${dcache[$e|$name]}"
            d1="$name  $(awk -F'\t' '$1 == "X" { print tolower($4) "  " $6 }' <<<"$recs")  $e"
            [[ "$proj" != default ]] && d1+="  project: $proj"
            d2="Proxies: $(awk -F'\t' '$1 == "D" { sub(/^[a-z]+:[^:]*:/, "", $4); sub(/^[a-z]+:[^:]*:/, "", $5); printf "%s->%s ", $4, $5 }' <<<"$recs")"
            d2="${d2%% }  Addresses: $(awk -F'\t' '$1 == "A" { printf "%s=%s ", $5, $4 }' <<<"$recs")"
            d3="Image: $(awk -F'\t' '$1 == "X" { print ($5 == "" ? "-" : $5) }' <<<"$recs")"
        }

        # _dports_browse_detail NAME ENGINE: set d1 d2 d3 (cached per reload)
        _dports_browse_detail() {
            local name="$1" status health started proj svc cimg run nets ports now_id w
            local _dports_dk="${2:-docker}"
            local -A seen=()
            d1="" d2="" d3=""
            if [[ "$name" == "("* ]]; then
                d1="$name is not a local container"
                return
            fi
            case "$2" in incus|lxd) _dports_browse_ic_detail "$name" "$2"; return ;; esac
            if [[ -z "${dcache[$name]+x}" ]]; then
                dcache[$name]=$(_dk inspect --format '{{.State.Status}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{end}}{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{.Config.Image}}{{"\t"}}{{.Image}}{{"\t"}}{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}{{"\t"}}{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}}->{{$p}} {{end}}{{end}}' \
                    "$name" 2>/dev/null | tr '\t' '\037')
                IFS=$'\037' read -r _ _ _ _ _ cimg _ <<<"${dcache[$name]}"
                [[ -n "$cimg" ]] && dcache[$name]+=$'\037'$(_dk image inspect --format '{{.Id}}' "$cimg" 2>/dev/null)
            fi
            IFS=$'\037' read -r status health started proj svc cimg run nets ports now_id <<<"${dcache[$name]}"
            if [[ -z "$status" ]]; then
                d1="$name: no such container (it may have been removed)"
                return
            fi
            d1="$name  $status${health:+ ($health)}"
            [[ "$status" == running && -n "$started" ]] && d1+="  since ${started:0:10} ${started:11:8} UTC"
            [[ -n "$proj" ]] && d1+="  compose: $proj/$svc"
            (( ${#engines[@]} > 1 )) && d1+="  $_dports_dk"
            for w in $ports; do [[ -z "${seen[$w]+x}" ]] && { seen[$w]=1; d2+="$w "; }; done
            d2="Ports: ${d2:--}  Networks: ${nets:--}"
            d3="Image: $cimg"
            [[ -n "$now_id" && -n "$run" && "$now_id" != "$run" ]] && d3+="  (runs an older image than this tag: recreate it to update)"
        }

        _dports_browse_draw() {
            local frame="" line title right r k_w n_w img_w f0 f1 f2 f3 f4 s count=${#shown[@]}
            local -a f=()
            _dports_tui_size
            local list_h=$(( rows - 9 ))
            (( list_h < 1 )) && list_h=1
            page=$list_h
            _dports_tui_scroll "$count" "$list_h"

            right="${#shown[@]}/${#all[@]} rows · "
            if [[ "$loading" == true ]]; then right+="loading..."
            elif (( interval > 0 )); then right+="refresh ${interval}s"
            else right+="refresh: r"; fi
            _dports_fit title " dports -I (experimental)" $(( cols - ${#right} - 1 ))
            frame+="$t_bold$title$t_reset $right${e}[K"$'\n'
            frame+="$t_dim$tui_rule$t_reset${e}[K"$'\n'

            k_w=10 n_w=10
            for (( r = 0; r < count; r++ )); do
                IFS=$'\t' read -r -a f <<<"${all[shown[r]]}"
                (( ${#f[1]} > k_w )) && k_w=${#f[1]}
                (( ${#f[2]} > n_w )) && n_w=${#f[2]}
            done
            (( k_w > 32 )) && k_w=32
            (( n_w > 28 )) && n_w=28
            img_w=$(( cols - 2 - 6 - 2 - k_w - 2 - n_w - 2 - 12 - 2 ))
            (( img_w < 8 )) && img_w=8
            _dports_fit f0 "KIND" 6; _dports_fit f1 "PORT/HOST" "$k_w"; _dports_fit f2 "CONTAINER" "$n_w"
            _dports_fit f3 "TARGET" 12; _dports_fit f4 "IMAGE" "$img_w"
            frame+="$t_dim  $f0  $f1  $f2  $f3  $f4$t_reset${e}[K"$'\n'
            for (( r = 0; r < list_h; r++ )); do
                j=$(( top + r )); line=""
                if (( j < count )); then
                    IFS=$'\t' read -r -a f <<<"${all[shown[j]]}"
                    _dports_fit f0 "${f[0]}" 6; _dports_fit f1 "${f[1]}" "$k_w"; _dports_fit f2 "${f[2]}" "$n_w"
                    _dports_fit f3 "${f[3]}" 12; _dports_fit f4 "${f[4]}" "$img_w"
                    if (( j == cur )); then
                        line="$t_rev> $f0  $f1  $f2  $f3  $f4$t_reset"
                    else
                        line="  $t_dim$f0$t_reset  $t_green$f1$t_reset  $t_cyan$f2$t_reset  $t_yellow$f3$t_reset  $f4"
                    fi
                elif (( r == 0 && count == 0 )); then
                    if [[ "$loaded" != true ]]; then line="  Loading..."
                    elif [[ -n "$query" ]]; then line="  No rows match \"$query\""
                    else line="  No published ports$([[ "$show_tunnel" == true ]] && echo " or tunnel routes")"; fi
                fi
                frame+="$line${e}[K"$'\n'
            done

            s=""
            if [[ "$typing" == true ]]; then s="Search: ${query}_"
            elif [[ -n "$query" ]]; then s="Search: $query  (Esc clears)"; fi
            (( top > 0 )) && s+="  ↑"
            (( top + list_h < count )) && s+="  ↓ more"
            _dports_tui_line line "$t_yellow" " $s"; frame+="$line"$'\n'
            frame+="$t_dim$tui_rule$t_reset${e}[K"$'\n'

            d1="" d2="" d3=""
            if (( count > 0 )); then
                IFS=$'\t' read -r -a f <<<"${all[shown[cur]]}"
                sel_id="${f[0]}|${f[1]}|${f[2]}"
                _dports_browse_detail "${f[2]}" "${f[7]:-}"
                [[ "${f[0]}" == tunnel ]] && d3="Tunnel: ${f[6]} -> ${f[5]}   $d3"
            fi
            _dports_tui_line line "$t_bold" " $d1"; frame+="$line"$'\n'
            _dports_tui_line line "" " $d2"; frame+="$line"$'\n'
            _dports_tui_line line "" " $d3"; frame+="$line"$'\n'
            if [[ -n "$msg" ]]; then
                _dports_tui_line line "$t_yellow" " $msg"
            elif [[ "$typing" == true ]]; then
                _dports_tui_line line "$t_dim" " Type to filter  Enter keep  Esc clear"
            else
                _dports_tui_line line "$t_dim" " ↑↓ move  / search  l logs  R restart  e shell  r refresh  q quit"
            fi
            frame+="$line"
            printf '%s' "${e}[H$frame${e}[J" >&3
        }

        # Logs of NAME under ENGINE (the console log for Incus/LXD)
        _dports_browse_logcmd() {
            local _dports_dk="$2" cli ic_name
            local -a ic_args=()
            case "$2" in
                incus|lxd)  cli=$(_dports_engine_cli "$2"); _dports_ic_target "$1"
                            "$cli" info "$ic_name" "${ic_args[@]}" --show-log 2>&1 ;;
                *)          _dk logs --tail 500 "$1" 2>&1 ;;
            esac
        }

        # Full-screen logs of NAME (last 500 lines, follows new output)
        _dports_browse_logs() {
            local name="$1" eng="${2:-docker}" ltop=0 follow=true lrc h r line s reload=true last=$SECONDS
            local -a L=()
            while true; do
                if [[ "$reload" == true ]] || { [[ "$follow" == true ]] && (( SECONDS - last >= 2 )); }; then
                    mapfile -t L < <(_dports_browse_logcmd "$name" "$eng" | tail -n 500)
                    for (( r = 0; r < ${#L[@]}; r++ )); do _dports_tui_clean "L[r]" "${L[r]}"; done
                    reload=false last=$SECONDS
                fi
                _dports_tui_size
                h=$(( rows - 3 )); (( h < 1 )) && h=1
                [[ "$follow" == true ]] && ltop=$(( ${#L[@]} - h ))
                (( ltop > ${#L[@]} - h )) && ltop=$(( ${#L[@]} - h ))
                (( ltop < 0 )) && ltop=0
                s="${#L[@]} lines · follow $([[ "$follow" == true ]] && echo on || echo off)"
                _dports_fit line " Logs: $name" $(( cols - ${#s} - 1 ))
                local frame="$t_bold$line$t_reset $s${e}[K"$'\n'"$t_dim$tui_rule$t_reset${e}[K"$'\n'
                for (( r = 0; r < h; r++ )); do
                    _dports_tui_line line "" " ${L[ltop + r]:-}"
                    (( ltop + r < ${#L[@]} )) || line="${e}[K"
                    frame+="$line"$'\n'
                done
                _dports_tui_line line "$t_dim" " ↑↓ PgUp/PgDn scroll  f follow  r reload  q back"
                printf '%s' "${e}[H$frame$line${e}[J" >&3
                _dports_tui_readkey 1; lrc=$?
                (( lrc == 2 )) && exit 1
                (( lrc == 1 )) && continue
                case "$key" in
                    up|k)       follow=false; (( ltop-- )) ;;
                    down|j)     (( ltop++ )); (( ltop >= ${#L[@]} - h )) && follow=true ;;
                    pgup)       follow=false; (( ltop -= h )) ;;
                    pgdn)       (( ltop += h )); (( ltop >= ${#L[@]} - h )) && follow=true ;;
                    home|g)     follow=false; ltop=0 ;;
                    end|G)      follow=true ;;
                    f)          if [[ "$follow" == true ]]; then follow=false; else follow=true; reload=true; fi ;;
                    r)          reload=true ;;
                    q|Q|esc)    return ;;
                esac
            done
        }

        # Open a shell in NAME on the normal screen, then come back
        _dports_browse_shell() {
            local name="$1" _dports_dk="${2:-docker}" src cli ic_name
            local -a ic_args=()
            local shell='if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'
            _dports_tui_leave
            printf '\n%s\n' "Shell in $name (exit it to return to dports -I)"
            case "$_dports_dk" in
                incus|lxd)  cli=$(_dports_engine_cli "$_dports_dk"); _dports_ic_target "$name"
                            "$cli" exec "$ic_name" "${ic_args[@]}" -- sh -c "$shell" </dev/tty >/dev/tty 2>&1 ;;
                *)          _dk exec -it "$name" sh -c "$shell" </dev/tty >/dev/tty 2>&1 ;;
            esac
            src=$?
            if (( src != 0 && src != 130 )); then
                printf '%s' "The shell ended with status $src. Press Enter to return to dports -I. " >/dev/tty
                read -r _ </dev/tty
            fi
            _dports_tui_resume
            unset "dcache[$name]"
        }

        _dports_browse_load
        while true; do
            (( tick++ ))
            if [[ "$loading" == true && -e "$tui_tmp/rows" ]]; then
                mapfile -t all < "$tui_tmp/rows"
                rm -f "$tui_tmp/rows"
                loading=false loaded=true
                dcache=()
                _dports_browse_filter
                _dports_browse_keep
            elif [[ "$loading" != true ]] && (( interval > 0 && SECONDS - loaded_at >= interval )) \
                    && [[ -z "$confirm" && "$typing" != true ]]; then
                _dports_browse_load
            fi
            if [[ -n "$busy" && -e "$tui_tmp/act.done" ]]; then
                if [[ "$(cat "$tui_tmp/act.done")" == 0 ]]; then
                    msg="$busy: done"
                else
                    msg="$busy: failed: $(grep . "$tui_tmp/act.log" | tail -1)"
                fi
                rm -f "$tui_tmp/act.done"
                busy=""
                _dports_browse_load
            fi

            _dports_browse_draw
            _dports_tui_readkey 0.5; rc=$?
            (( rc == 2 )) && exit 1
            (( rc == 1 )) && continue

            if [[ "$typing" == true ]]; then
                case "$key" in
                    enter)      typing=false ;;
                    esc)        typing=false query="" ;;
                    backspace)  query="${query%?}" ;;
                    space)      query+=" " ;;
                    ?)          query+="$key" ;;
                esac
                _dports_browse_filter; cur=0 top=0
                continue
            fi

            if [[ -n "$confirm" ]]; then
                if [[ "$key" == y || "$key" == Y ]]; then
                    busy="Restart $confirm"
                    msg="Restarting $confirm..."
                    (
                        case "$confirm_eng" in
                            incus|lxd)  _dports_ic_target "$confirm"
                                        "$(_dports_engine_cli "$confirm_eng")" restart "$ic_name" "${ic_args[@]}" ;;
                            *)          _dports_dk="${confirm_eng:-docker}"; _dk restart "$confirm" ;;
                        esac > "$tui_tmp/act.log" 2>&1
                        echo $? > "$tui_tmp/act.res"
                        mv -f "$tui_tmp/act.res" "$tui_tmp/act.done"
                    ) &
                else
                    msg="Restart cancelled"
                fi
                confirm=""
                continue
            fi
            [[ -z "$busy" ]] && msg=""

            _dports_tui_move "${#shown[@]}" "$page" && continue
            local name="" eng=""
            if (( ${#shown[@]} )); then
                IFS=$'\t' read -r -a f <<<"${all[shown[cur]]}"
                name="${f[2]}" eng="${f[7]:-docker}"
            fi
            case "$key" in
                /)          typing=true ;;
                esc)        if [[ -n "$query" ]]; then query=""; _dports_browse_filter; else exit 0; fi ;;
                q|Q)        exit 0 ;;
                r)          [[ "$loading" == true ]] || _dports_browse_load ;;
                l|L)        if [[ -n "$name" && "$name" != "("* ]]; then _dports_browse_logs "$name" "$eng"
                            else msg="No local container on this row"; fi ;;
                R)          if [[ -n "$busy" ]]; then msg="$busy is still running"
                            elif [[ -n "$name" && "$name" != "("* ]]; then confirm="$name" confirm_eng="$eng"; msg="Restart $name? (y/n)"
                            else msg="No local container on this row"; fi ;;
                e|E)        if [[ -n "$name" && "$name" != "("* ]]; then _dports_browse_shell "$name" "$eng"
                            else msg="No local container on this row"; fi ;;
            esac
        done
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
            -I|--interactive)
                interactive=true
                shift
                ;;
            --engine)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --engine requires a list (docker, podman, incus, lxd, auto)" >&2
                    return 1
                fi
                engine_opt="$2"
                shift 2
                ;;
            --engine=*)
                engine_opt="${1#*=}"
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
            engines)
                _dports_config_load
                _dports_engines_resolve || return 1
                _dports_engines_report
                return 0
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

    _dports_config_load
    [[ -z "$DPORTS_TIMEOUT" && -n "$cfg_timeout" ]] && DPORTS_TIMEOUT="$cfg_timeout"
    [[ -z "$DPORTS_REFRESH" && -n "$cfg_refresh" ]] && DPORTS_REFRESH="$cfg_refresh"
    _dports_engines_resolve || return 1

    # One engine that is not installed: say so plainly
    if (( ${#engines[@]} == 1 )) && ! command -v "$(_dports_engine_cli "${engines[0]}")" &>/dev/null; then
        if [[ "${engines[0]}" == docker ]]; then
            echo "Error: Docker is not installed or not in PATH" >&2
        else
            echo "Error: $(_dports_engine_cli "${engines[0]}") is not installed or not in PATH" >&2
        fi
        return 1
    fi

    if [[ "$interactive" == true ]]; then
        if [[ "$quiet" == true || "$json_output" == true ]]; then
            echo "Error: -I cannot be combined with -q or -j" >&2
            return 1
        fi
        ( _dports_browse )
        return $?
    fi

    # With -q/-j, --tunnel prints only the tunnel routes (one kind of record)
    if [[ "$show_tunnel" == true && ( "$quiet" == true || "$json_output" == true ) ]]; then
        _dports_tunnel_section
        return
    fi

    # PORT<TAB>NAME<TAB>INTERNAL<TAB>IMAGE<TAB>ENGINE, one line per published
    # port (this also tells whether the engines are reachable)
    local results
    if ! results=$(_dports_all_rows); then
        if [[ "${engines[*]}" == docker ]]; then
            echo "Error: Cannot connect to Docker daemon." >&2
            echo "Is Docker running? Do you have permission to access it?" >&2
        else
            echo "Error: Cannot connect to ${engines[*]}." >&2
            echo "Is it running? Do you have permission to access it? ('dports engines' shows what is in use)" >&2
        fi
        return 1
    fi

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

    # Output formatting (an ENGINE column when more than one engine is in use)
    local port name internal image engine multi=false
    (( ${#engines[@]} > 1 )) && multi=true
    if [[ "$quiet" == true ]]; then
        # Quiet mode: just port numbers
        cut -f1 <<<"$results" | uniq
    elif [[ "$json_output" == true ]]; then
        # JSON output
        echo "["
        local prev="" line
        while IFS=$'\t' read -r port name internal image engine; do
            line=$(printf '  {"port": "%s", "name": "%s", "internal": "%s", "image": "%s", "engine": "%s"}' \
                "$port" "$name" "$internal" "$image" "$engine")
            if [[ -n "$prev" ]]; then
                printf '%s,\n' "$prev"
            fi
            prev="$line"
        done <<< "$results"
        if [[ -n "$prev" ]]; then
            printf '%s\n' "$prev"
        fi
        echo "]"
    elif [[ "$verbose" == true && "$multi" == true ]]; then
        printf "${C_BOLD}%-8s  %-28s  %-15s  %-7s  %s${C_RESET}\n" "PORT" "NAME" "INTERNAL" "ENGINE" "IMAGE"
        printf "${C_DIM}%-8s  %-28s  %-15s  %-7s  %s${C_RESET}\n" \
            "────────" "────────────────────────────" "───────────────" "───────" "────────────────────────"
        while IFS=$'\t' read -r port name internal image engine; do
            printf "${C_GREEN}%-8s${C_RESET}  ${C_CYAN}%-28s${C_RESET}  ${C_YELLOW}%-15s${C_RESET}  %-7s  %s\n" \
                "$port" "$name" "$internal" "$engine" "$image"
        done <<< "$results"
    elif [[ "$verbose" == true ]]; then
        # Verbose mode with internal port
        printf "${C_BOLD}%-8s  %-28s  %-15s  %s${C_RESET}\n" "PORT" "NAME" "INTERNAL" "IMAGE"
        printf "${C_DIM}%-8s  %-28s  %-15s  %s${C_RESET}\n" \
            "────────" "────────────────────────────" "───────────────" "────────────────────────"
        while IFS=$'\t' read -r port name internal image engine; do
            printf "${C_GREEN}%-8s${C_RESET}  ${C_CYAN}%-28s${C_RESET}  ${C_YELLOW}%-15s${C_RESET}  %s\n" \
                "$port" "$name" "$internal" "$image"
        done <<< "$results"
    elif [[ "$multi" == true ]]; then
        printf "${C_BOLD}%-8s  %-28s  %-7s  %s${C_RESET}\n" "PORT" "NAME" "ENGINE" "IMAGE"
        printf "${C_DIM}%-8s  %-28s  %-7s  %s${C_RESET}\n" \
            "────────" "────────────────────────────" "───────" "────────────────────────"
        while IFS=$'\t' read -r port name image engine; do
            printf "${C_GREEN}%-8s${C_RESET}  ${C_CYAN}%-28s${C_RESET}  %-7s  %s\n" \
                "$port" "$name" "$engine" "$image"
        done < <(cut -f1,2,4,5 <<<"$results" | uniq)
    else
        # Standard mode (tcp and udp on the same port show once)
        printf "${C_BOLD}%-8s  %-28s  %s${C_RESET}\n" "PORT" "NAME" "IMAGE"
        printf "${C_DIM}%-8s  %-28s  %s${C_RESET}\n" \
            "────────" "────────────────────────────" "────────────────────────"
        while IFS=$'\t' read -r port name image; do
            printf "${C_GREEN}%-8s${C_RESET}  ${C_CYAN}%-28s${C_RESET}  %s\n" \
                "$port" "$name" "$image"
        done < <(cut -f1,2,4 <<<"$results" | uniq)
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
