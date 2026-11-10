## v2.5.0

### Highlights
- `dports update` is one full-screen flow: checking, choosing, pulling and recreating, with live status per image and a summary left in the terminal when you exit.
- New recreate screen: containers that run an older image than their tag, one row per Compose service. Enter recreates the service under the cursor, Space selects, `s` recreates the selected ones, `A` all of them (also as buttons: Tab, Left/Right, Enter). dports runs `docker compose up -d --no-deps SERVICE` in the project directory.
- `dports update --yes --recreate` does the same without asking; `--check` now lists outdated containers too.
- `dports -I` (experimental): browse ports (and tunnel routes with `-t`) with search, container details, logs, restart, shell and live refresh.
- Zsh support (`install.sh --zsh`, completion in the Debian package). Fish and Zsh run `dports.bash`, so every feature works the same in all three shells.

### Notes
- Tag: `v2.5.0`
- Containers not managed by Docker Compose cannot be recreated automatically; they are listed with a hint.
- The Debian package no longer ships the Fish function (Fish uses `/usr/bin/dports`); its completions are still installed.
