## v2.4.0

### Highlights
- `dports update` has its own full-screen checklist (no whiptail/dialog needed). It lists each image with its status and the containers that use it, explains why a status is unknown, scrolls, follows terminal resizes, and has keys to select images with updates (`u`), all (`a`) or none (`n`).
- Only images with an update are selected by default. Locally built images now show as `local`, separate from `unknown`; neither is pre-selected.
- `dports update --check` reports without pulling (also the behaviour without a terminal); `dports update --yes` pulls every update without asking.
- After pulling, dports prints the `docker compose up -d …` command that recreates the affected containers.
- Checks show live progress, run at most 8 registry queries at a time and time out after 30 s each (`DPORTS_TIMEOUT`).

### Fixes
- 32-bit ARM hosts without buildx compared against the wrong arm variant and always reported an update.
- `-C/--no-color` is honoured by `dports update`, and options after `update` are no longer ignored.

### Notes
- Tag: `v2.4.0`
- Fish runs `dports update` from `dports.bash`; the installer copies it to `~/.local/share/dports/`, and the Debian package provides it as `/usr/bin/dports`.
- The Debian package needs Bash 4.3+ and no longer recommends whiptail.
