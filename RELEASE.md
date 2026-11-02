## v2.4.0

### Highlights
- `dports update` has its own full-screen checklist (whiptail/dialog are no longer needed). It lists each image with its status and the containers that use it, explains why a status is unknown, scrolls, follows terminal resizes, and has keys to select images with updates (`u`), all (`a`) or none (`n`).
- Only images with an update are selected by default. Locally built images show as `local`, separate from `unknown`; neither is pre-selected.
- `dports update --check` reports without pulling (also the behaviour without a terminal); `dports update --yes` pulls every update without asking.
- After pulling, dports prints the `docker compose up -d ...` command that recreates the affected containers.

### Fixes
- 32-bit ARM hosts without buildx always reported an update (wrong arm variant).
- `dports -t` printed a bogus `*  ()` row when cloudflared's metrics server returned no rules; it now falls back to the config file.
- `install.sh uninstall` no longer removes the system-wide Debian package without asking (`--apt` / `--no-apt` decide explicitly).
- The installer downloads the files of its own release tag, and ignores the current directory when piped to bash.
- `make deb` no longer depends on the umask (the first v2.4.0 build failed under umask 000).

### Notes
- Tag: `v2.4.0`
- The Debian package lists Docker under Suggests instead of Depends, needs Bash 4.3+, and no longer recommends whiptail.
- Fish runs `dports update` from `dports.bash` (`/usr/bin/dports` in the package, `~/.local/share/dports/dports.bash` with the installer).
- The changelog moved from the README to `CHANGELOG.md`.
