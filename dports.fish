#
# dports - Display Docker container port mappings (Fish front end)
# https://git.palnarium.com/JonPark0/dports
#
# Version: 2.5.0
# License: MIT
#
# dports is implemented once, in dports.bash; this function runs it with
# bash, so every option and the interactive screens work the same in Fish.
#
# Installation (install.sh does this):
#   ~/.config/fish/functions/dports.fish            this file
#   ~/.config/fish/completions/dports.fish          completions
#   ~/.local/share/dports/dports.bash               the implementation
# With the Debian package, /usr/bin/dports is used and this file is not needed.
#

set -g DPORTS_VERSION "2.5.0"

# Path of this file: dports.bash is also looked up next to it (git checkout)
set -g __dports_source (realpath (status current-filename) 2>/dev/null)

function dports --description "Display Docker container port mappings"
    set -l data_dir $XDG_DATA_HOME
    test -n "$data_dir"; or set data_dir $HOME/.local/share
    set -l here (string replace -r '/[^/]*$' '' -- "$__dports_source")
    set -l impl
    for f in $DPORTS_BASH $data_dir/dports/dports.bash $here/dports.bash (command -s dports)
        if test -f "$f"; and grep -q '^DPORTS_VERSION=' "$f" 2>/dev/null
            set impl $f
            break
        end
    end
    if test -z "$impl"
        echo "Error: dports.bash was not found." >&2
        echo "Reinstall with 'install.sh --fish' or 'sudo apt install dports'," >&2
        echo "or point DPORTS_BASH at a copy of dports.bash." >&2
        return 1
    end
    if not command -q bash
        echo "Error: dports needs bash (4.3 or newer)." >&2
        return 1
    end
    bash $impl $argv
end
