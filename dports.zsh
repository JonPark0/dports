#
# dports - Display Docker container port mappings (Zsh front end)
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.6.0
# License: MIT
#
# dports is implemented once, in dports.bash; this function runs it with
# bash, so every option and the interactive screens work the same in Zsh.
#
# Installation (install.sh does this): source this file from ~/.zshrc, with
# dports.bash in ~/.local/share/dports/ and the completion function _dports
# in ~/.local/share/dports/zsh/. With the Debian package, /usr/bin/dports
# and /usr/share/zsh/vendor-completions/_dports are used instead.
#

typeset -g DPORTS_VERSION="2.6.0"
typeset -g _DPORTS_ZSH_DIR="${${(%):-%x}:A:h}"

dports() {
    emulate -L zsh
    local impl f
    for f in "$DPORTS_BASH" "${XDG_DATA_HOME:-$HOME/.local/share}/dports/dports.bash" \
             "$_DPORTS_ZSH_DIR/dports.bash" "${commands[dports]}"; do
        if [[ -n "$f" && -f "$f" ]] && grep -q '^DPORTS_VERSION=' "$f" 2>/dev/null; then
            impl="$f"
            break
        fi
    done
    if [[ -z "$impl" ]]; then
        print -u2 "Error: dports.bash was not found."
        print -u2 "Reinstall with 'install.sh --zsh' or 'sudo apt install dports',"
        print -u2 "or point DPORTS_BASH at a copy of dports.bash."
        return 1
    fi
    if (( ! $+commands[bash] )); then
        print -u2 "Error: dports needs bash (4.3 or newer)."
        return 1
    fi
    bash "$impl" "$@"
}

# Completion: _dports next to this file (git checkout) or in ./zsh/ (installer)
() {
    local dir
    for dir in "$_DPORTS_ZSH_DIR/zsh" "$_DPORTS_ZSH_DIR/completions"; do
        if [[ -f "$dir/_dports" ]]; then
            fpath=("$dir" $fpath)
            autoload -Uz _dports
            (( $+functions[compdef] )) && compdef _dports dports
            break
        fi
    done
}
