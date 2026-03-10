#!/usr/bin/env bash
#
# dports interactive installer
# Automatically detects shells and provides checkbox selection
#

VERSION="2.1.2"
REPO_URL="https://git.palnarium.com/JonPark0/dports/raw/branch/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Symbols
CHECK="✔"
UNCHECK="✗"

# State
declare -A SHELLS_AVAILABLE
declare -A SHELLS_SELECTED
declare -a SHELL_ORDER=()

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
        bash_ver=$(bash --version | head -n1 | grep -oP '\d+\.\d+' | head -1)
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
        fish_ver=$(fish --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        SHELLS_AVAILABLE["fish"]="Fish ${fish_ver}"
        SHELLS_SELECTED["fish"]=true
        SHELL_ORDER+=("fish")
        echo -e "  ${GREEN}${CHECK}${NC} Fish ${fish_ver} detected"
    else
        echo -e "  ${DIM}${UNCHECK} Fish not found${NC}"
    fi
    
    # Check Zsh (for future support)
    if command -v zsh &>/dev/null; then
        local zsh_ver
        zsh_ver=$(zsh --version | grep -oP '\d+\.\d+' | head -1)
        echo -e "  ${DIM}${UNCHECK} Zsh ${zsh_ver} detected (not yet supported)${NC}"
    fi
    
    echo
    
    if [[ ${#SHELL_ORDER[@]} -eq 0 ]]; then
        error "No supported shells found!"
        echo "dports requires Bash or Fish shell."
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

# Show progress gauge
show_progress() {
    local title="$1"
    local percent="$2"
    local message="$3"
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        echo "$percent" | "$dialog_tool" --title "$title" --gauge "$message" 8 50 "$percent"
    fi
}

# Run a command with progress display
run_with_progress() {
    local title="$1"
    local message="$2"
    shift 2
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        "$dialog_tool" --title "$title" --infobox "$message" 8 50
    else
        echo -e "${CYAN}→${NC} $message"
    fi
}

run_checkbox_selection() {
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    
    if [[ -z "$dialog_tool" ]]; then
        warn "Neither whiptail nor dialog found. Using simple selection."
        run_simple_selection
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
    trap "rm -f '$tmpfile'" EXIT INT TERM HUP

    "$dialog_tool" \
        --title "dports Installer" \
        --checklist "Select shells to install:\n\nUse SPACE to toggle, ENTER to confirm" \
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
        echo "Installation cancelled."
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
    echo
    echo -e "${BOLD}Select shells to install:${NC}"
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
                echo "Installation cancelled."
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

get_source_file() {
    local filename="$1"
    local dest="$2"
    
    # Try local file first
    if [[ -f "${SCRIPT_DIR}/${filename}" ]]; then
        cp "${SCRIPT_DIR}/${filename}" "$dest"
        return 0
    fi
    
    # Download from repo
    if command -v curl &>/dev/null; then
        curl -fsSL "${REPO_URL}/${filename}" -o "$dest"
        return $?
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "${REPO_URL}/${filename}"
        return $?
    else
        error "Neither curl nor wget found. Cannot download files."
        return 1
    fi
}

install_bash() {
    local bash_func_dir="$HOME/.bash_functions"
    local bashrc="$HOME/.bashrc"
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    local use_dialog=false
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        use_dialog=true
    fi
    
    if [[ "$use_dialog" == true ]]; then
        # Show progress with whiptail
        {
            echo 10
            sleep 0.2
            mkdir -p "$bash_func_dir"
            
            echo 30
            sleep 0.2
            
            echo 50
            if [[ -f "${SCRIPT_DIR}/dports.bash" ]]; then
                cp "${SCRIPT_DIR}/dports.bash" "$bash_func_dir/dports"
            elif command -v curl &>/dev/null; then
                curl -fsSL "${REPO_URL}/dports.bash" -o "$bash_func_dir/dports" 2>/dev/null
            elif command -v wget &>/dev/null; then
                wget -qO "$bash_func_dir/dports" "${REPO_URL}/dports.bash" 2>/dev/null
            fi
            chmod +x "$bash_func_dir/dports"
            
            echo 80
            sleep 0.2
            
            # Add to bashrc if needed
            if ! grep -q "bash_functions" "$bashrc" 2>/dev/null; then
                cat >> "$bashrc" << 'BASHRC'

# Load all functions from ~/.bash_functions (added by dports installer)
if [ -d ~/.bash_functions ]; then
    for func in ~/.bash_functions/*; do
        [ -f "$func" ] && . "$func"
    done
fi
BASHRC
            fi
            
            echo 100
            sleep 0.2
        } | "$dialog_tool" --title "Installing Bash" --gauge "Installing dports for Bash..." 8 50 0
    else
        # Text-based progress
        echo -e "  ${CYAN}→${NC} Creating ${bash_func_dir}..."
        mkdir -p "$bash_func_dir"
        
        echo -e "  ${CYAN}→${NC} Installing dports function..."
        if ! get_source_file "dports.bash" "$bash_func_dir/dports"; then
            error "Failed to install Bash function"
            return 1
        fi
        chmod +x "$bash_func_dir/dports"
        
        # Check if bashrc sources functions directory
        if ! grep -q "bash_functions" "$bashrc" 2>/dev/null; then
            echo -e "  ${CYAN}→${NC} Adding function loader to ~/.bashrc..."
            cat >> "$bashrc" << 'BASHRC'

# Load all functions from ~/.bash_functions (added by dports installer)
if [ -d ~/.bash_functions ]; then
    for func in ~/.bash_functions/*; do
        [ -f "$func" ] && . "$func"
    done
fi
BASHRC
        else
            echo -e "  ${DIM}→ Function loader already exists in ~/.bashrc${NC}"
        fi
        
        success "Bash installation complete"
        echo -e "      ${DIM}Location: ${bash_func_dir}/dports${NC}"
        echo -e "      ${DIM}Run: ${BOLD}source ~/.bashrc${NC}${DIM} or start a new terminal${NC}"
    fi
    
    return 0
}

install_fish() {
    local fish_func_dir="$HOME/.config/fish/functions"
    local dialog_tool
    dialog_tool=$(get_dialog_tool)
    local use_dialog=false
    
    if [[ -n "$dialog_tool" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
        use_dialog=true
    fi
    
    if [[ "$use_dialog" == true ]]; then
        # Show progress with whiptail
        {
            echo 20
            sleep 0.2
            mkdir -p "$fish_func_dir"
            
            echo 50
            sleep 0.2
            
            if [[ -f "${SCRIPT_DIR}/dports.fish" ]]; then
                cp "${SCRIPT_DIR}/dports.fish" "$fish_func_dir/dports.fish"
            elif command -v curl &>/dev/null; then
                curl -fsSL "${REPO_URL}/dports.fish" -o "$fish_func_dir/dports.fish" 2>/dev/null
            elif command -v wget &>/dev/null; then
                wget -qO "$fish_func_dir/dports.fish" "${REPO_URL}/dports.fish" 2>/dev/null
            fi
            
            echo 100
            sleep 0.2
        } | "$dialog_tool" --title "Installing Fish" --gauge "Installing dports for Fish..." 8 50 0
    else
        # Text-based progress
        echo -e "  ${CYAN}→${NC} Creating ${fish_func_dir}..."
        mkdir -p "$fish_func_dir"
        
        echo -e "  ${CYAN}→${NC} Installing dports function..."
        if ! get_source_file "dports.fish" "$fish_func_dir/dports.fish"; then
            error "Failed to install Fish function"
            return 1
        fi
        
        success "Fish installation complete"
        echo -e "      ${DIM}Location: ${fish_func_dir}/dports.fish${NC}"
        echo -e "      ${DIM}Function is immediately available${NC}"
    fi
    
    return 0
}

uninstall_bash() {
    local bash_func="$HOME/.bash_functions/dports"
    
    if [[ -f "$bash_func" ]]; then
        rm -f "$bash_func"
        success "Removed Bash function: $bash_func"
    else
        warn "Bash function not found at $bash_func"
    fi
}

uninstall_fish() {
    local fish_func="$HOME/.config/fish/functions/dports.fish"
    
    if [[ -f "$fish_func" ]]; then
        rm -f "$fish_func"
        success "Removed Fish function: $fish_func"
    else
        warn "Fish function not found at $fish_func"
    fi
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
            
            show_message "Installation Complete ✔" "$completion_msg"
            
            # Offer to start a new shell session
            offer_shell_restart "${selected_shells[@]}"
        else
            # Text-based completion message
            echo
            echo -e "${GREEN}${BOLD}╭─────────────────────────────────────────╮${NC}"
            echo -e "${GREEN}${BOLD}│      Installation Complete! 🎉          │${NC}"
            echo -e "${GREEN}${BOLD}╰─────────────────────────────────────────╯${NC}"
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
    
    # For Bash, offer to start new session
    if [[ "$current_shell" == "bash" ]] && [[ "$current_shell_installed" == true ]]; then
        if [[ "$use_dialog" == true ]]; then
            if "$dialog_tool" --title "Apply Changes" --yesno "Would you like to start a new shell session with dports enabled?\n\nSelect 'Yes' to start a new $current_shell session.\nSelect 'No' to manually run: source ~/.bashrc" 12 55; then
                clear
                echo -e "${GREEN}Starting new shell session with dports enabled...${NC}"
                echo -e "${DIM}Type 'exit' to return to your original session.${NC}"
                echo
                exec "$SHELL"
            else
                show_message "Manual Activation" "To activate dports in your current session, run:\n\n  source ~/.bashrc\n\nOr simply start a new terminal."
            fi
        else
            echo -e "${YELLOW}To activate dports in your current session:${NC}"
            echo -e "  ${CYAN}source ~/.bashrc${NC}"
            echo
            read -rp "Start a new shell session now? [y/N] " response
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
                    msg+="• Bash: Run 'source ~/.bashrc' or start a new terminal\n"
                elif [[ "$shell" == "fish" ]]; then
                    msg+="• Fish: Available immediately (auto-loaded)\n"
                fi
            done
            show_message "Activation Required" "$msg"
        else
            echo -e "${BOLD}To use dports:${NC}"
            for shell in "${installed_shells[@]}"; do
                if [[ "$shell" == "bash" ]]; then
                    echo -e "  • Bash: Run ${CYAN}source ~/.bashrc${NC} or start a new terminal"
                elif [[ "$shell" == "fish" ]]; then
                    echo -e "  • Fish: Available immediately (auto-loaded)"
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
    
    for shell in "${SHELL_ORDER[@]}"; do
        if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
            if [[ "$use_dialog" == true ]]; then
                show_info "Uninstalling" "Removing dports for ${shell^}..."
                sleep 0.5
            fi
            
            "uninstall_${shell}"
            uninstalled+=("$shell")
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
    --all         All detected shells (skip interactive selection)
    --simple      Use simple text menu (if whiptail unavailable)
    --yes, -y     Skip confirmation prompts
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
    local auto_yes=false
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
            --all)
                skip_selection=true
                shift
                ;;
            --simple)
                use_simple=true
                shift
                ;;
            --yes|-y)
                auto_yes=true
                shift
                ;;
            --no-color)
                RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
                CHECK="[x]" UNCHECK="[ ]" ARROW=">"
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
        run_simple_selection
    else
        # Interactive checkbox selection
        run_checkbox_selection
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