# Fish completions for dports
#
# Installed to ~/.config/fish/completions/ (installer) or
# /usr/share/fish/vendor_completions.d/ (Debian package), so fish loads
# them on the first <TAB> instead of only after dports has been run.

complete -c dports -f
complete -c dports -n "__fish_use_subcommand" -a update -d "Check for image updates (TUI)"
complete -c dports -n "__fish_seen_subcommand_from update" -l check -d "Only report image status"
complete -c dports -n "__fish_seen_subcommand_from update" -s y -l yes -d "Pull every update without asking"
complete -c dports -s v -l verbose -d "Show detailed port mapping"
complete -c dports -s a -l all -d "Include stopped containers"
complete -c dports -s p -l port -d "Filter by port number" -x
complete -c dports -s n -l name -d "Filter by container name" -x
complete -c dports -s i -l image -d "Filter by image name" -x
complete -c dports -s c -l color -d "Force color output"
complete -c dports -s C -l no-color -d "Disable color output"
complete -c dports -s t -l tunnel -d "Also show Cloudflare Tunnel routes"
complete -c dports -s q -l quiet -d "Only show port numbers"
complete -c dports -s j -l json -d "Output in JSON format"
complete -c dports -s h -l help -d "Show help message"
complete -c dports -s V -l version -d "Show version"
