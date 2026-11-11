#!/usr/bin/env bash
#
# dports interactive installer
# Automatically detects shells and provides checkbox selection
#

VERSION="2.6.0"
# Files are downloaded from the release tag that matches this installer
# (DPORTS_REF overrides it, e.g. DPORTS_REF=branch/main)
REPO_RAW="https://git.palnarium.com/JonPark0/dports/raw"
REPO_REF="${DPORTS_REF:-tag/v${VERSION}}"
# Local files are used only when this script is a file on disk; when it is
# piped (curl ... | bash) the current directory must not be trusted.
SCRIPT_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Colors (real escape bytes, so they also work in heredocs; off when piped)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# Symbols
CHECK="[x]"
UNCHECK="[ ]"

# State
declare -A SHELLS_AVAILABLE
declare -A SHELLS_SELECTED
declare -a SHELL_ORDER=()
AUTO_YES=false
REMOVE_APT=ask      # ask | yes (--apt) | no

# ─────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────

print_banner() {
    echo
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
     _                  _       
  __| |_ __   ___  _ __| |_ ___ 
 / _` | '_ \ / _ \| '__| __/ __|
| (_| | |_) | (_) | |  | |_\__ \
 \__,_| .__/ \___/|_|   \__|___/
      |_|                       
EOF
    echo -e "${NC}"
    echo -e "${DIM}Docker container port mapping tool - v${VERSION}${NC}"
    echo
}

# ─────────────────────────────────────────────────────────────
# Shell Detection
# ─────────────────────────────────────────────────────────────

detect_shells() {
    info "Detecting available shells..."
    echo
    
    # Check Bash
    if command -v bash &>/dev/null; then
        local bash_ver
        bash_ver=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        SHELLS_AVAILABLE["bash"]="Bash ${bash_ver}"
        SHELLS_SELECTED["bash"]=true
        SHELL_ORDER+=("bash")
        echo -e "  ${GREEN}${CHECK}${NC} Bash ${bash_ver} detected"
    else
        echo -e "  ${DIM}${UNCHECK} Bash not found${NC}"
    fi
    
    # Check Fish
    if command -v fish &>/dev/null; then
        local fish_ver
        fish_ver=$(fish --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        SHELLS_AVAILABLE["fish"]="Fish ${fish_ver}"
        SHELLS_SELECTED["fish"]=true
        SHELL_ORDER+=("fish")
        echo -e "  ${GREEN}${CHECK}${NC} Fish ${fish_ver} detected"
    else
        echo -e "  ${DIM}${UNCHECK} Fish not found${NC}"
    fi
    
    # Check Zsh
    if command -v zsh &>/dev/null; then
        local zsh_ver
        zsh_ver=$(zsh --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        SHELLS_AVAILABLE["zsh"]="Zsh ${zsh_ver}"
        SHELLS_SELECTED["zsh"]=true
        SHELL_ORDER+=("zsh")
        echo -e "  ${GREEN}${CHECK}${NC} Zsh ${zsh_ver} detected"
    else
        echo -e "  ${DIM}${UNCHECK} Zsh not found${NC}"
    fi
    
    echo
    
    if [[ ${#SHELL_ORDER[@]} -eq 0 ]]; then
        error "No supported shells found!"
        echo "dports requires Bash, Fish or Zsh."
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────
# Interactive Selection (whiptail or fallback)
# ─────────────────────────────────────────────────────────────

# Check if whiptail or dialog is available
DIALOG_TOOL=""

get_dialog_tool() {
    if [[ -n "$DIALOG_TOOL" ]]; then
        echo "$DIALOG_TOOL"
        return
    fi
    
    if command -v whiptail &>/dev/null; then
        DIALOG_TOOL="whiptail"
    elif command -v dialog &>/dev/null; then
        DIALOG_TOOL="dialog"
    else
        DIALOG_TOOL=""
    fi
    echo "$DIALOG_TOOL"
}

# Show info box (non-blocking message)
show_info() {
    local title="$1"
    local message="$2"
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        "$dialog_tool" --title "$title" --infobox "$message" 8 50
    else
        echo -e "${BLUE}[$title]${NC} $message"
    fi
}

# Show message box (blocking, requires user to press OK)
show_message() {
    local title="$1"
    local message="$2"
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        "$dialog_tool" --title "$title" --msgbox "$message" 12 60
    else
        echo
        echo -e "${BOLD}=== $title ===${NC}"
        echo -e "$message"
        echo
    fi
}

# Usage: run_checkbox_selection [VERB]   (VERB: "install" or "uninstall")
run_checkbox_selection() {
    local verb="${1:-install}"
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    
    if [[ -z "$dialog_tool" ]]; then
        warn "Neither whiptail nor dialog found. Using simple selection."
        run_simple_selection "$verb"
        return $?
    fi
    
    # Check if we're in an interactive terminal
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        warn "Non-interactive terminal detected. Using all detected shells."
        return 0
    fi
    
    # Build checklist options
    local options=()
    for shell in "${SHELL_ORDER[@]}"; do
        local name="${SHELLS_AVAILABLE[$shell]}"
        local state="ON"
        if [[ "${SHELLS_SELECTED[$shell]}" != "true" ]]; then
            state="OFF"
        fi
        options+=("$shell" "$name" "$state")
    done
    
    # Calculate dialog size
    local height=$((${#SHELL_ORDER[@]} + 10))
    local width=50
    local list_height=${#SHELL_ORDER[@]}
    
    # Run whiptail/dialog checklist
    # Capture result and exit code separately
    local result=""
    local exit_code=0
    
    # Use temp file for more reliable capture
    local tmpfile
    tmpfile=$(mktemp)
    # shellcheck disable=SC2064  # expand now: tmpfile is a local variable
    trap "rm -f '$tmpfile'" EXIT INT TERM HUP

    "$dialog_tool" \
        --title "dports Installer" \
        --checklist "Select shells to ${verb}:\n\nUse SPACE to toggle, ENTER to confirm" \
        "$height" "$width" "$list_height" \
        "${options[@]}" \
        2>"$tmpfile"

    exit_code=$?
    result=$(cat "$tmpfile")
    rm -f "$tmpfile"
    trap - EXIT INT TERM HUP
    
    # Check if user cancelled
    if [[ $exit_code -ne 0 ]]; then
        echo
        echo "Cancelled."
        exit 0
    fi
    
    # Parse result - deselect all first
    for shell in "${SHELL_ORDER[@]}"; do
        SHELLS_SELECTED[$shell]=false
    done
    
    # Then select the ones returned by whiptail
    # whiptail returns: "bash" "fish" (quoted, space-separated)
    if [[ -n "$result" ]]; then
        # Remove all quotes and iterate
        result="${result//\"/}"
        for shell in $result; do
            if [[ -n "${SHELLS_AVAILABLE[$shell]}" ]]; then
                SHELLS_SELECTED[$shell]=true
            fi
        done
    fi
    
    return 0
}

# Simple fallback selection for non-working terminals
run_simple_selection() {
    local verb="${1:-install}"
    echo
    echo -e "${BOLD}Select shells to ${verb}:${NC}"
    echo
    
    local i=1
    for shell in "${SHELL_ORDER[@]}"; do
        local name="${SHELLS_AVAILABLE[$shell]}"
        local status=""
        if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
            status="${GREEN}[selected]${NC}"
        fi
        echo "  $i) $name $status"
        ((i++))
    done
    echo "  a) Select all"
    echo "  n) Select none"
    echo "  c) Continue with current selection"
    echo "  q) Quit"
    echo
    
    while true; do
        echo -n "Enter choice: "
        read -r choice
        
        case "$choice" in
            [1-9])
                local idx=$((choice - 1))
                if [[ $idx -lt ${#SHELL_ORDER[@]} ]]; then
                    local shell="${SHELL_ORDER[$idx]}"
                    if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
                        SHELLS_SELECTED[$shell]=false
                        echo "  Deselected: ${SHELLS_AVAILABLE[$shell]}"
                    else
                        SHELLS_SELECTED[$shell]=true
                        echo "  Selected: ${SHELLS_AVAILABLE[$shell]}"
                    fi
                else
                    echo "  Invalid option"
                fi
                ;;
            a|A)
                for shell in "${SHELL_ORDER[@]}"; do
                    SHELLS_SELECTED[$shell]=true
                done
                echo "  Selected all shells"
                ;;
            n|N)
                for shell in "${SHELL_ORDER[@]}"; do
                    SHELLS_SELECTED[$shell]=false
                done
                echo "  Deselected all shells"
                ;;
            c|C|'')
                echo
                return 0
                ;;
            q|Q)
                echo "Cancelled."
                exit 0
                ;;
            *)
                echo "  Invalid option. Try again."
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────
# Installation Functions
# ─────────────────────────────────────────────────────────────

FISH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
# Fish and Zsh run this copy of dports.bash (the whole implementation)
DPORTS_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dports"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
ZSH_LOADER_MARK="# dports (added by dports installer)"

# Returns 0 when whiptail/dialog can be used for the current terminal
use_dialog() {
    [[ -n "$(get_dialog_tool)" ]] && [[ -t 0 ]] && [[ -t 1 ]]
}

# download URL DEST
download() {
    if command -v curl &>/dev/null; then
        curl -fsSL "$1" -o "$2"
    else
        wget -qO "$2" "$1"
    fi
}

# Copy FILENAME from next to this script (or download it) to DEST.
# The file is fetched into a temp file first, so a failed download never
# clobbers an existing installation.
get_source_file() {
    local filename="$1"
    local dest="$2"
    local tmp="${dest}.tmp.$$"

    if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${filename}" ]]; then
        cp "${SCRIPT_DIR}/${filename}" "$tmp" || { rm -f "$tmp"; return 1; }
    elif ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        error "Neither curl nor wget found. Cannot download files."
        return 1
    elif ! download "${REPO_RAW}/${REPO_REF}/${filename}" "$tmp"; then
        # Before the release tag exists, fall back to the main branch
        if [[ -n "${DPORTS_REF:-}" ]] || ! download "${REPO_RAW}/branch/main/${filename}" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    fi

    # Reject empty files and error pages
    if [[ ! -s "$tmp" ]] || ! grep -q "dports" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
}

# Append the ~/.bash_functions loader to ~/.bashrc unless one exists.
# Returns 1 if a loader was already present.
add_bash_loader() {
    local bashrc="$HOME/.bashrc"
    grep -q "bash_functions" "$bashrc" 2>/dev/null && return 1
    cat >> "$bashrc" << 'BASHRC'

# Load all functions from ~/.bash_functions (added by dports installer)
if [ -d ~/.bash_functions ]; then
    for func in ~/.bash_functions/*; do
        [ -f "$func" ] && . "$func"
    done
fi
BASHRC
}

install_bash() {
    local bash_func_dir="$HOME/.bash_functions"
    local dest="$bash_func_dir/dports"

    if use_dialog; then
        # The gauge runs in a pipeline subshell, so report success via a file
        local status_file
        status_file=$(mktemp)
        {
            echo 10
            mkdir -p "$bash_func_dir"
            echo 40
            if get_source_file "dports.bash" "$dest" 2>/dev/null; then
                chmod +x "$dest"
                echo 80
                add_bash_loader
                echo ok > "$status_file"
            fi
            echo 100
            sleep 0.3
        } | "$(get_dialog_tool)" --title "Installing Bash" --gauge "Installing dports for Bash..." 8 50 0

        local result
        result=$(cat "$status_file"); rm -f "$status_file"
        if [[ "$result" != ok ]]; then
            error "Failed to install Bash function"
            return 1
        fi
    else
        # Text-based progress
        echo -e "  ${CYAN}-${NC} Creating ${bash_func_dir}..."
        mkdir -p "$bash_func_dir"

        echo -e "  ${CYAN}-${NC} Installing dports function..."
        if ! get_source_file "dports.bash" "$dest"; then
            error "Failed to install Bash function"
            return 1
        fi
        chmod +x "$dest"

        if add_bash_loader; then
            echo -e "  ${CYAN}-${NC} Added function loader to ~/.bashrc"
        else
            echo -e "  ${DIM}- Function loader already exists in ~/.bashrc${NC}"
        fi

        success "Bash installation complete"
        echo -e "      ${DIM}Location: ${dest}${NC}"
        echo -e "      ${DIM}Run: ${BOLD}source ~/.bashrc${NC}${DIM} or start a new terminal${NC}"
    fi

    return 0
}

install_fish() {
    local fish_func_dir="$FISH_CONFIG_DIR/functions"
    local fish_comp_dir="$FISH_CONFIG_DIR/completions"

    if use_dialog; then
        local status_file
        status_file=$(mktemp)
        {
            echo 20
            mkdir -p "$fish_func_dir" "$fish_comp_dir" "$DPORTS_DATA_DIR"
            echo 40
            if get_source_file "dports.fish" "$fish_func_dir/dports.fish" 2>/dev/null \
                && get_source_file "dports.bash" "$DPORTS_DATA_DIR/dports.bash" 2>/dev/null; then
                echo 80
                # Completions are optional; a failure here is not fatal
                get_source_file "completions/dports.fish" "$fish_comp_dir/dports.fish" 2>/dev/null
                echo ok > "$status_file"
            fi
            echo 100
            sleep 0.3
        } | "$(get_dialog_tool)" --title "Installing Fish" --gauge "Installing dports for Fish..." 8 50 0

        local result
        result=$(cat "$status_file"); rm -f "$status_file"
        if [[ "$result" != ok ]]; then
            error "Failed to install Fish function"
            return 1
        fi
    else
        # Text-based progress
        echo -e "  ${CYAN}-${NC} Creating ${fish_func_dir}..."
        mkdir -p "$fish_func_dir" "$fish_comp_dir" "$DPORTS_DATA_DIR"

        echo -e "  ${CYAN}-${NC} Installing dports function..."
        if ! get_source_file "dports.fish" "$fish_func_dir/dports.fish"; then
            error "Failed to install Fish function"
            return 1
        fi

        echo -e "  ${CYAN}-${NC} Installing dports.bash (the implementation)..."
        if ! get_source_file "dports.bash" "$DPORTS_DATA_DIR/dports.bash"; then
            error "Failed to install ${DPORTS_DATA_DIR}/dports.bash (the implementation dports.fish runs)"
            return 1
        fi

        echo -e "  ${CYAN}-${NC} Installing tab completions..."
        if ! get_source_file "completions/dports.fish" "$fish_comp_dir/dports.fish"; then
            warn "Could not install Fish completions (dports itself works)"
        fi

        success "Fish installation complete"
        echo -e "      ${DIM}Location: ${fish_func_dir}/dports.fish${NC}"
        echo -e "      ${DIM}Function is immediately available${NC}"
    fi

    return 0
}

# Append the dports.zsh loader to ~/.zshrc unless it is there.
# Returns 1 if a loader was already present.
add_zsh_loader() {
    grep -qF "$ZSH_LOADER_MARK" "$ZSHRC" 2>/dev/null && return 1
    cat >> "$ZSHRC" << 'ZSHRC'

# dports (added by dports installer)
[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/dports/dports.zsh" ] && source "${XDG_DATA_HOME:-$HOME/.local/share}/dports/dports.zsh"
ZSHRC
}

# Copy the Zsh front end, its completion and dports.bash to DPORTS_DATA_DIR
install_zsh_files() {
    mkdir -p "$DPORTS_DATA_DIR/zsh" || return 1
    get_source_file "dports.bash" "$DPORTS_DATA_DIR/dports.bash" || return 1
    get_source_file "dports.zsh" "$DPORTS_DATA_DIR/dports.zsh" || return 1
    # Completions are optional; a failure here is not fatal
    get_source_file "completions/_dports" "$DPORTS_DATA_DIR/zsh/_dports" \
        || warn "Could not install Zsh completions (dports itself works)"
    return 0
}

install_zsh() {
    if use_dialog; then
        local status_file
        status_file=$(mktemp)
        {
            echo 20
            if install_zsh_files 2>/dev/null; then
                echo 80
                add_zsh_loader
                echo ok > "$status_file"
            fi
            echo 100
            sleep 0.3
        } | "$(get_dialog_tool)" --title "Installing Zsh" --gauge "Installing dports for Zsh..." 8 50 0

        local result
        result=$(cat "$status_file"); rm -f "$status_file"
        if [[ "$result" != ok ]]; then
            error "Failed to install the Zsh front end"
            return 1
        fi
    else
        echo -e "  ${CYAN}-${NC} Installing dports.zsh, completions and dports.bash to ${DPORTS_DATA_DIR}..."
        if ! install_zsh_files; then
            error "Failed to install the Zsh front end"
            return 1
        fi
        if add_zsh_loader; then
            echo -e "  ${CYAN}-${NC} Added the dports loader to ${ZSHRC}"
        else
            echo -e "  ${DIM}- The dports loader already exists in ${ZSHRC}${NC}"
        fi
        success "Zsh installation complete"
        echo -e "      ${DIM}Location: ${DPORTS_DATA_DIR}/dports.zsh${NC}"
        echo -e "      ${DIM}Run: ${BOLD}source ${ZSHRC}${NC}${DIM} or start a new terminal${NC}"
    fi
    return 0
}

# Remove the shared dports.bash once neither Fish nor Zsh uses it
cleanup_data_dir() {
    if [[ ! -f "$FISH_CONFIG_DIR/functions/dports.fish" && ! -f "$DPORTS_DATA_DIR/dports.zsh" \
          && -f "$DPORTS_DATA_DIR/dports.bash" ]]; then
        rm -f "$DPORTS_DATA_DIR/dports.bash"
        success "Removed $DPORTS_DATA_DIR/dports.bash"
    fi
    rmdir "$DPORTS_DATA_DIR/zsh" "$DPORTS_DATA_DIR" 2>/dev/null
    return 0
}

# Ask a yes/no question (default: no). Never asks without a terminal.
confirm() {
    local question="$1" answer=""
    if use_dialog; then
        "$(get_dialog_tool)" --title "dports Installer" --defaultno --yesno "$question" 10 60
        return
    fi
    [[ -t 0 ]] || return 1
    read -rp "$question [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# The Debian package is system-wide (all users), so it is removed only when
# asked for with --apt or confirmed interactively, never as a side effect.
uninstall_apt() {
    dpkg -s dports &>/dev/null || return 1
    case "$REMOVE_APT" in
        no) return 1 ;;
        ask)
            if ! confirm "dports is also installed as a Debian package (for all users). Remove it with 'sudo apt-get remove dports'?"; then
                info "Kept the Debian package (remove it with: sudo apt remove dports)"
                return 1
            fi ;;
    esac
    info "Removing the Debian package..."
    if sudo apt-get remove -y dports || sudo dpkg -r dports; then
        success "Removed apt package: dports"
        return 0
    fi
    error "Failed to remove apt package. Try: sudo apt remove dports"
    return 1
}

uninstall_bash() {
    local bash_func_dir="$HOME/.bash_functions"
    local bashrc="$HOME/.bashrc"
    local removed=false f rc

    # Remove files in ~/.bash_functions/ that define the dports function
    # (not every file that merely mentions "dports")
    if [[ -d "$bash_func_dir" ]]; then
        while IFS= read -r -d '' f; do
            if grep -qE '^(dports[[:space:]]*\(\)|function[[:space:]]+dports)' "$f" 2>/dev/null; then
                rm -f "$f"
                success "Removed Bash function file: $f"
                removed=true
            fi
        done < <(find "$bash_func_dir" -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    # Remove inline function block from dotfiles (older install method)
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        if grep -qE '^(# dports shell function|dports[[:space:]]*\(\)|function[[:space:]]+dports)' "$rc"; then
            cp -p "$rc" "${rc}.dports-backup"
            sed -i \
                -e '/^# dports shell function/,/^}$/d' \
                -e '/^dports[[:space:]]*()/,/^}$/d' \
                -e '/^function[[:space:]]\{1,\}dports/,/^}$/d' \
                "$rc"
            success "Removed inline dports function from $rc (backup: ${rc}.dports-backup)"
            removed=true
        fi
    done

    # Remove the loader this installer added, once nothing is left to load
    local loader='^# Load all functions from ~/\.bash_functions (added by dports installer)$'
    if [[ ! -d "$bash_func_dir" || -z "$(ls -A "$bash_func_dir" 2>/dev/null)" ]] \
        && grep -q "$loader" "$bashrc" 2>/dev/null; then
        sed -i '/^# Load all functions from ~\/\.bash_functions (added by dports installer)$/,/^fi$/d' "$bashrc"
        info "Removed the ~/.bash_functions loader from ~/.bashrc"
    fi

    if [[ "$removed" != true ]]; then
        warn "No Bash installation found in $bash_func_dir or dotfiles"
        return 1
    fi
    return 0
}

uninstall_fish() {
    local removed=false f

    for f in "$FISH_CONFIG_DIR/functions/dports.fish" "$FISH_CONFIG_DIR/completions/dports.fish"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            success "Removed $f"
            removed=true
        fi
    done
    cleanup_data_dir

    if [[ "$removed" != true ]]; then
        warn "Fish function not found in $FISH_CONFIG_DIR/functions"
        return 1
    fi
    return 0
}

uninstall_zsh() {
    local removed=false f

    for f in "$DPORTS_DATA_DIR/dports.zsh" "$DPORTS_DATA_DIR/zsh/_dports"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            success "Removed $f"
            removed=true
        fi
    done
    if grep -qF "$ZSH_LOADER_MARK" "$ZSHRC" 2>/dev/null; then
        cp -p "$ZSHRC" "${ZSHRC}.dports-backup"
        # The marker line, the loader line after it, and the blank line before
        awk -v mark="$ZSH_LOADER_MARK" '
            skip { skip = 0; next }
            $0 == mark { skip = 1; if (held && prev == "") held = 0; next }
            { if (held) print prev; prev = $0; held = 1 }
            END { if (held) print prev }' "${ZSHRC}.dports-backup" > "$ZSHRC"
        success "Removed the dports loader from $ZSHRC (backup: ${ZSHRC}.dports-backup)"
        removed=true
    fi
    cleanup_data_dir

    if [[ "$removed" != true ]]; then
        warn "No Zsh installation found in $DPORTS_DATA_DIR or $ZSHRC"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
# Main Installation Flow
# ─────────────────────────────────────────────────────────────

run_install() {
    local selected_count=0
    local selected_shells=()
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    local use_dialog=false
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        use_dialog=true
    fi
    
    # Collect selected shells
    for shell in "${SHELL_ORDER[@]}"; do
        if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
            ((selected_count++))
            selected_shells+=("$shell")
        fi
    done
    
    if [[ $selected_count -eq 0 ]]; then
        if [[ "$use_dialog" == true ]]; then
            show_message "No Selection" "No shells selected. Nothing to install."
        else
            warn "No shells selected. Nothing to install."
        fi
        exit 0
    fi
    
    if [[ "$use_dialog" != true ]]; then
        echo -e "${BOLD}Installing dports for: ${selected_shells[*]}${NC}"
        echo
    fi
    
    # Install for each selected shell
    local install_errors=0
    for shell in "${selected_shells[@]}"; do
        if [[ "$use_dialog" != true ]]; then
            echo -e "${BOLD}[${shell^}]${NC}"
        fi
        
        if ! "install_${shell}"; then
            ((install_errors++))
        fi
        
        if [[ "$use_dialog" != true ]]; then
            echo
        fi
    done
    
    # Show completion message
    if [[ $install_errors -gt 0 ]]; then
        if [[ "$use_dialog" == true ]]; then
            show_message "Installation Warning" "Installation completed with $install_errors error(s).\n\nSome shells may not have been installed correctly."
        else
            warn "Installation completed with $install_errors error(s)."
        fi
    else
        if [[ "$use_dialog" == true ]]; then
            local completion_msg="dports has been installed successfully!\n\n"
            completion_msg+="Installed for: ${selected_shells[*]}\n\n"
            completion_msg+="Quick Start:\n"
            completion_msg+="  dports          List container ports\n"
            completion_msg+="  dports -v       Verbose mode\n"
            completion_msg+="  dports -p 8080  Filter by port\n"
            completion_msg+="  dports --help   Show all options"
            
            show_message "Installation Complete" "$completion_msg"
            
            # Offer to start a new shell session
            offer_shell_restart "${selected_shells[@]}"
        else
            # Text-based completion message
            echo
            echo -e "${GREEN}${BOLD}Installation complete.${NC}"
            echo
            echo -e "${BOLD}Quick Start:${NC}"
            echo -e "  ${CYAN}dports${NC}          List all container ports"
            echo -e "  ${CYAN}dports -v${NC}       Verbose mode (show internal ports)"
            echo -e "  ${CYAN}dports -p 8080${NC}  Filter by port"
            echo -e "  ${CYAN}dports -n nginx${NC} Filter by name"
            echo -e "  ${CYAN}dports --help${NC}   Show all options"
            echo
            
            # Offer to start a new shell session
            offer_shell_restart "${selected_shells[@]}"
        fi
    fi
}

# Offer to restart shell or source the configuration
offer_shell_restart() {
    local installed_shells=("$@")
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    local use_dialog=false
    local current_shell
    
    # Detect current shell
    current_shell=$(basename "$SHELL")
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        use_dialog=true
    fi
    
    # Check if current shell was installed
    local current_shell_installed=false
    for shell in "${installed_shells[@]}"; do
        if [[ "$shell" == "$current_shell" ]]; then
            current_shell_installed=true
            break
        fi
    done
    
    # Fish auto-loads functions, no restart needed
    if [[ "$current_shell" == "fish" ]] && [[ "$current_shell_installed" == true ]]; then
        if [[ "$use_dialog" == true ]]; then
            show_message "Ready to Use" "Fish shell auto-loads functions.\n\ndports is now available immediately!\n\nTry running: dports --help"
        else
            echo -e "${GREEN}Fish shell auto-loads functions. dports is ready to use!${NC}"
            echo
        fi
        return 0
    fi
    
    # For Bash and Zsh, offer to start new session (skipped with --yes)
    # shellcheck disable=SC2088  # shown to the user, not expanded
    local rcfile="~/.bashrc"
    [[ "$current_shell" == "zsh" ]] && rcfile="${ZSHRC/#$HOME/~}"
    if [[ "$current_shell" == "bash" || "$current_shell" == "zsh" ]] && [[ "$current_shell_installed" == true ]] \
        && [[ "$AUTO_YES" != true ]]; then
        if [[ "$use_dialog" == true ]]; then
            if "$dialog_tool" --title "Apply Changes" --yesno "Would you like to start a new shell session with dports enabled?\n\nSelect 'Yes' to start a new $current_shell session.\nSelect 'No' to manually run: source $rcfile" 12 55; then
                clear
                echo -e "${GREEN}Starting new shell session with dports enabled...${NC}"
                echo -e "${DIM}Type 'exit' to return to your original session.${NC}"
                echo
                exec "$SHELL"
            else
                show_message "Manual Activation" "To activate dports in your current session, run:\n\n  source $rcfile\n\nOr simply start a new terminal."
            fi
        else
            echo -e "${YELLOW}To activate dports in your current session:${NC}"
            echo -e "  ${CYAN}source $rcfile${NC}"
            echo
            local response=""
            [[ -t 0 ]] && read -rp "Start a new shell session now? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                echo
                echo -e "${GREEN}Starting new shell session...${NC}"
                echo -e "${DIM}Type 'exit' to return to your original session.${NC}"
                echo
                exec "$SHELL"
            fi
        fi
    else
        # Different shell or shell not installed
        if [[ "$use_dialog" == true ]]; then
            local msg="To use dports:\n\n"
            for shell in "${installed_shells[@]}"; do
                if [[ "$shell" == "bash" ]]; then
                    msg+="- Bash: Run 'source ~/.bashrc' or start a new terminal\n"
                elif [[ "$shell" == "fish" ]]; then
                    msg+="- Fish: Available immediately (auto-loaded)\n"
                elif [[ "$shell" == "zsh" ]]; then
                    msg+="- Zsh: Run 'source ${ZSHRC/#$HOME/~}' or start a new terminal\n"
                fi
            done
            show_message "Activation Required" "$msg"
        else
            echo -e "${BOLD}To use dports:${NC}"
            for shell in "${installed_shells[@]}"; do
                if [[ "$shell" == "bash" ]]; then
                    echo -e "  - Bash: Run ${CYAN}source ~/.bashrc${NC} or start a new terminal"
                elif [[ "$shell" == "fish" ]]; then
                    echo -e "  - Fish: Available immediately (auto-loaded)"
                elif [[ "$shell" == "zsh" ]]; then
                    echo -e "  - Zsh: Run ${CYAN}source ${ZSHRC/#$HOME/~}${NC} or start a new terminal"
                fi
            done
            echo
        fi
    fi
}

run_uninstall() {
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    local use_dialog=false
    local uninstalled=()

    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        use_dialog=true
    fi

    if [[ "$use_dialog" != true ]]; then
        echo -e "${BOLD}Uninstalling dports...${NC}"
        echo
    fi

    # Remove the apt/dpkg package if present and wanted (see uninstall_apt)
    if uninstall_apt; then
        uninstalled+=("apt")
    fi

    # Remove per-user installs (~/.bash_functions, ~/.config/fish, ~/.zshrc, ~/.local/share/dports)
    for shell in "${SHELL_ORDER[@]}"; do
        if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
            if [[ "$use_dialog" == true ]]; then
                show_info "Uninstalling" "Removing dports for ${shell^}..."
                sleep 0.5
            fi

            if "uninstall_${shell}"; then
                uninstalled+=("$shell")
            fi
        fi
    done

    # Show completion
    if [[ "$use_dialog" == true ]]; then
        show_message "Uninstall Complete" "dports has been removed.\n\nUninstalled from: ${uninstalled[*]}"
    else
        echo
        success "Uninstallation complete!"
    fi
}

# ─────────────────────────────────────────────────────────────
# CLI Argument Parsing
# ─────────────────────────────────────────────────────────────

usage() {
    cat << EOF
${BOLD}dports installer${NC} - v${VERSION}

${BOLD}USAGE:${NC}
    $0 [COMMAND] [OPTIONS]

${BOLD}COMMANDS:${NC}
    install       Interactive installation (default)
    uninstall     Remove dports from system
    help          Show this help message

${BOLD}OPTIONS:${NC}
    --bash        Only Bash (skip interactive selection)
    --fish        Only Fish (skip interactive selection)
    --zsh         Only Zsh (skip interactive selection)
    --all         All detected shells (skip interactive selection)
    --simple      Use simple text menu (if whiptail unavailable)
    --yes, -y     Skip confirmation prompts
    --apt         uninstall: also remove the Debian package (system-wide)
    --no-apt      uninstall: never touch the Debian package
    --no-color    Disable colored output

${BOLD}EXAMPLES:${NC}
    $0                    # Interactive installation (uses whiptail)
    $0 install --all      # Install for all detected shells
    $0 install --bash     # Install for Bash only
    $0 --simple           # Use simple text menu
    $0 uninstall          # Interactive uninstall
    $0 uninstall --all    # Uninstall from all shells

${BOLD}REQUIREMENTS:${NC}
    whiptail or dialog    For interactive menus (optional)
    curl or wget          For downloading files

EOF
}

main() {
    local command="install"
    local skip_selection=false
    local target_shells=()
    local use_simple=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install)
                command="install"
                shift
                ;;
            uninstall|remove)
                command="uninstall"
                shift
                ;;
            help|--help|-h)
                usage
                exit 0
                ;;
            --bash)
                target_shells+=("bash")
                skip_selection=true
                shift
                ;;
            --fish)
                target_shells+=("fish")
                skip_selection=true
                shift
                ;;
            --zsh)
                target_shells+=("zsh")
                skip_selection=true
                shift
                ;;
            --all)
                skip_selection=true
                shift
                ;;
            --simple)
                use_simple=true
                shift
                ;;
            --yes|-y)
                AUTO_YES=true
                shift
                ;;
            --apt)
                REMOVE_APT=yes
                shift
                ;;
            --no-apt)
                REMOVE_APT=no
                shift
                ;;
            --no-color)
                RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
                shift
                ;;
            --version|-V)
                echo "dports installer v${VERSION}"
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                echo "Run '$0 --help' for usage."
                exit 1
                ;;
        esac
    done
    
    # Print banner
    print_banner
    
    # Detect shells
    detect_shells
    
    # Apply CLI shell selection (if specified)
    if [[ "$skip_selection" == true ]]; then
        if [[ ${#target_shells[@]} -gt 0 ]]; then
            # Specific shells requested - deselect all first
            for shell in "${SHELL_ORDER[@]}"; do
                SHELLS_SELECTED[$shell]=false
            done
            # Then select only requested ones
            for shell in "${target_shells[@]}"; do
                if [[ -n "${SHELLS_AVAILABLE[$shell]}" ]]; then
                    SHELLS_SELECTED[$shell]=true
                else
                    warn "$shell is not available on this system"
                fi
            done
        fi
        # If --all, keep all detected shells selected (default)
    elif [[ "$use_simple" == true ]]; then
        # Use simple numbered selection
        run_simple_selection "$command"
    else
        # Interactive checkbox selection
        run_checkbox_selection "$command"
    fi
    
    # Run command
    case "$command" in
        install)
            run_install
            ;;
        uninstall)
            run_uninstall
            ;;
    esac
}

# Entry point
main "$@"
