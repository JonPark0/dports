#!/usr/bin/env bash
#
# dports interactive installer
# Automatically detects shells and provides checkbox selection
#

set -e

VERSION="2.0.0"
REPO_URL="https://raw.githubusercontent.com/yeochoon/dports/main"
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
UNCHECK="○"
ARROW="❯"
BOX_H="─"
BOX_V="│"
BOX_TL="╭"
BOX_TR="╮"
BOX_BL="╰"
BOX_BR="╯"

# State
declare -A SHELLS_AVAILABLE
declare -A SHELLS_SELECTED
declare -a SHELL_ORDER=()
CURRENT_INDEX=0

# ─────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Hide/show cursor
cursor_hide() { printf '\033[?25l'; }
cursor_show() { printf '\033[?25h'; }

# Move cursor
cursor_up()    { printf '\033[%sA' "${1:-1}"; }
cursor_down()  { printf '\033[%sB' "${1:-1}"; }
cursor_save()  { printf '\033[s'; }
cursor_restore() { printf '\033[u'; }

# Clear line
clear_line() { printf '\033[2K\r'; }

# Terminal state management
ORIGINAL_STTY=""

save_terminal() {
    ORIGINAL_STTY=$(stty -g 2>/dev/null) || true
}

restore_terminal() {
    if [[ -n "$ORIGINAL_STTY" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
}

# Cleanup on exit
cleanup() {
    cursor_show
    restore_terminal
}
trap cleanup EXIT INT TERM

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
# Interactive Checkbox UI
# ─────────────────────────────────────────────────────────────

draw_checkbox_menu() {
    local total=${#SHELL_ORDER[@]}
    
    # Draw box top
    echo -e "${BOX_TL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_TR}"
    echo -e "${BOX_V}  ${BOLD}Select shells to install:${NC}              ${BOX_V}"
    echo -e "${BOX_V}                                         ${BOX_V}"
    
    for i in "${!SHELL_ORDER[@]}"; do
        local shell="${SHELL_ORDER[$i]}"
        local name="${SHELLS_AVAILABLE[$shell]}"
        local selected="${SHELLS_SELECTED[$shell]}"
        local checkbox
        local prefix="   "
        local color=""
        
        if [[ "$selected" == "true" ]]; then
            checkbox="${GREEN}[${CHECK}]${NC}"
        else
            checkbox="${DIM}[ ]${NC}"
        fi
        
        if [[ $i -eq $CURRENT_INDEX ]]; then
            prefix=" ${CYAN}${ARROW}${NC} "
            color="${BOLD}"
        fi
        
        # Pad the name to fixed width
        local padded_name
        padded_name=$(printf "%-29s" "$name")
        
        echo -e "${BOX_V}${prefix}${checkbox} ${color}${padded_name}${NC}${BOX_V}"
    done
    
    echo -e "${BOX_V}                                         ${BOX_V}"
    echo -e "${BOX_V}${DIM}  ↑↓ Navigate  Space Toggle  Enter Done ${NC}${BOX_V}"
    echo -e "${BOX_V}${DIM}  a  All       q     Quit               ${NC}${BOX_V}"
    echo -e "${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_BR}"
}

redraw_menu() {
    local total=${#SHELL_ORDER[@]}
    # Lines: top border + title + empty + options + empty + help1 + help2 + bottom border
    local lines=$((total + 7))
    
    cursor_up "$lines"
    draw_checkbox_menu
}

toggle_current() {
    local shell="${SHELL_ORDER[$CURRENT_INDEX]}"
    if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
        SHELLS_SELECTED[$shell]=false
    else
        SHELLS_SELECTED[$shell]=true
    fi
}

toggle_all() {
    # Check if all are selected
    local all_selected=true
    for shell in "${SHELL_ORDER[@]}"; do
        if [[ "${SHELLS_SELECTED[$shell]}" != "true" ]]; then
            all_selected=false
            break
        fi
    done
    
    # Toggle: if all selected, deselect all; otherwise select all
    local new_state="true"
    if [[ "$all_selected" == "true" ]]; then
        new_state="false"
    fi
    
    for shell in "${SHELL_ORDER[@]}"; do
        SHELLS_SELECTED[$shell]=$new_state
    done
}

move_up() {
    if [[ $CURRENT_INDEX -gt 0 ]]; then
        ((CURRENT_INDEX--))
    fi
}

move_down() {
    local max=$((${#SHELL_ORDER[@]} - 1))
    if [[ $CURRENT_INDEX -lt $max ]]; then
        ((CURRENT_INDEX++))
    fi
}

run_checkbox_selection() {
    # Check if we're in an interactive terminal
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        warn "Non-interactive terminal detected. Using all detected shells."
        return 0
    fi
    
    echo -e "${BOLD}Installation Options${NC}"
    echo
    
    # Save terminal state
    save_terminal
    
    # Draw initial menu
    draw_checkbox_menu
    
    # Hide cursor and set raw mode
    cursor_hide
    stty raw -echo 2>/dev/null || {
        cursor_show
        restore_terminal
        warn "Cannot configure terminal. Falling back to simple mode."
        run_simple_selection
        return $?
    }
    
    # Input loop
    while true; do
        # Read one byte
        local char
        char=$(dd bs=1 count=1 2>/dev/null)
        local code=$(printf '%d' "'$char" 2>/dev/null || echo 0)
        
        # Handle input
        case "$code" in
            # Enter (13 = CR, 10 = LF)
            13|10)
                break
                ;;
            # Space (32)
            32)
                toggle_current
                redraw_menu
                ;;
            # 'a' or 'A' (97, 65)
            97|65)
                toggle_all
                redraw_menu
                ;;
            # 'q' or 'Q' (113, 81)
            113|81)
                cursor_show
                restore_terminal
                echo
                echo
                echo "Installation cancelled."
                exit 0
                ;;
            # 'j' (106) - down
            106)
                move_down
                redraw_menu
                ;;
            # 'k' (107) - up
            107)
                move_up
                redraw_menu
                ;;
            # Escape (27) - start of arrow key sequence
            27)
                # Read next two characters for arrow keys
                local seq1 seq2
                seq1=$(dd bs=1 count=1 2>/dev/null)
                seq2=$(dd bs=1 count=1 2>/dev/null)
                local seq1_code=$(printf '%d' "'$seq1" 2>/dev/null || echo 0)
                local seq2_code=$(printf '%d' "'$seq2" 2>/dev/null || echo 0)
                
                # Arrow keys: ESC [ A/B/C/D (27 91 65/66/67/68)
                if [[ $seq1_code -eq 91 ]]; then
                    case "$seq2_code" in
                        65) # Up arrow
                            move_up
                            redraw_menu
                            ;;
                        66) # Down arrow
                            move_down
                            redraw_menu
                            ;;
                    esac
                fi
                ;;
            # Ctrl+C (3)
            3)
                cursor_show
                restore_terminal
                echo
                echo
                echo "Installation cancelled."
                exit 130
                ;;
        esac
    done
    
    # Restore terminal
    cursor_show
    restore_terminal
    echo
    echo
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
}

install_fish() {
    local fish_func_dir="$HOME/.config/fish/functions"
    
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
    
    # Collect selected shells
    for shell in "${SHELL_ORDER[@]}"; do
        if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
            ((selected_count++))
            selected_shells+=("$shell")
        fi
    done
    
    if [[ $selected_count -eq 0 ]]; then
        warn "No shells selected. Nothing to install."
        exit 0
    fi
    
    echo -e "${BOLD}Installing dports for: ${selected_shells[*]}${NC}"
    echo
    
    for shell in "${selected_shells[@]}"; do
        echo -e "${BOLD}[${shell^}]${NC}"
        "install_${shell}"
        echo
    done
    
    # Print success summary
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
}

run_uninstall() {
    echo -e "${BOLD}Uninstalling dports...${NC}"
    echo
    
    for shell in "${SHELL_ORDER[@]}"; do
        if [[ "${SHELLS_SELECTED[$shell]}" == "true" ]]; then
            "uninstall_${shell}"
        fi
    done
    
    echo
    success "Uninstallation complete!"
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
    --simple      Use simple numbered menu (if arrow keys don't work)
    --yes, -y     Skip confirmation prompts
    --no-color    Disable colored output

${BOLD}EXAMPLES:${NC}
    $0                    # Interactive installation
    $0 install --all      # Install for all detected shells
    $0 install --bash     # Install for Bash only
    $0 --simple           # Use simple menu (for problematic terminals)
    $0 uninstall          # Interactive uninstall
    $0 uninstall --all    # Uninstall from all shells

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