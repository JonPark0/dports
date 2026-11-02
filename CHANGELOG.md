# Changelog

## v2.4.2

### Bug fixes
- The `dports update` report (shown with `--check`, without a terminal, or when everything is up to date) capped the IMAGE column at 50 characters, so longer names pushed their STATUS out of line. The column now fits the longest name. The full-screen checklist still shortens long names and shows the full name in the line under the list.

## v2.4.1

### Bug fixes
- `dports update` showed locally built images as `unknown` on the containerd image store (the Docker Engine 29+ default), where they also have a registry digest. Images that their registry does not have (for example a bare name like `myapp` that is not on Docker Hub) are now `local`.
- The reason under the checklist now says why a registry query failed: Docker Hub rate limit, login needed (with the registry name), registry unreachable, or no answer within `DPORTS_TIMEOUT`.

## v2.4.0

### New features
- `dports update` has its own full-screen checklist instead of whiptail/dialog. It shows the containers that use each image and why a status is unknown, scrolls, follows terminal resizes, and has keys to select images with updates, all or none.
- New `local` status for locally built images, separate from `unknown`. Only images with an update are selected by default.
- `dports update --check` (report only) and `--yes` (pull every update). Without a terminal, `update` only reports.
- After pulling, dports prints the `docker compose up -d` command that recreates the affected containers.
- Live progress while checking; at most 8 registry queries at a time, each limited to 30 s (`DPORTS_TIMEOUT`).
- Installer: `uninstall --apt` / `--no-apt` to decide about the Debian package explicitly.

### Bug fixes
- 32-bit ARM hosts without buildx compared against the wrong arm variant and always reported an update.
- `dports update` ignored `-C/--no-color` and every option given after `update`.
- `dports -t` printed a bogus `*  ()` row, and skipped the tunnel's config file, when cloudflared's metrics server answered without any ingress rule.
- `install.sh uninstall` removed the system-wide Debian package with sudo even when only one shell was selected; it now asks first (or follows `--apt` / `--no-apt`).
- The installer downloaded files from the `main` branch instead of the release it belongs to, and, when piped to bash, used files from the current directory.
- `make deb` failed with "control directory has bad permissions 777" under umask 000, as in some CI containers.

### Changes
- Fish runs `dports update` from `dports.bash`, so there is one implementation; the installer keeps a copy in `~/.local/share/dports/`.
- `dports` no longer runs `docker info` before every listing; the `docker ps` call reports an unreachable daemon.
- Debian package: needs Bash 4.3+, no longer recommends whiptail, and lists Docker under Suggests instead of Depends (apt installed docker.io on hosts whose Docker came from snap or static binaries). The empty maintainer scripts are gone.
- `make test` runs the update tests against a fake docker CLI; the release workflow runs them too.
- Documentation rewritten without emoji; this changelog moved out of the README.

## v2.3.0

### New features
- `-t/--tunnel`: list Cloudflare Tunnel hostnames and the containers they route to, read from cloudflared's metrics server (including dashboard-managed tunnels) or its config file

### Bug fixes
- `dports update` reported every image as outdated on the containerd image store (the Docker Engine 29+ default); updates are now detected from `RepoDigests` and work on both image stores
- `dports update` no longer lists containers still running an old image as bare image IDs, skips digest-pinned images, and no longer prints job-control noise (`[1] 1234`) when run as a shell function
- Removed `eval` of dialog output and the traps that overwrote the calling shell's own traps
- Fish: update checks now really run in parallel, and completions are shipped separately so they work before the first `dports` run
- `-a/--all` now shows the port bindings of stopped containers (they were never displayed)
- Installer: `--help` printed raw escape codes; the dialog UI reported success even when the download failed; uninstall deleted any file in `~/.bash_functions` that merely mentioned "dports"; `--yes` was ignored
- Debian package: `fish` moved from Recommends to Suggests (apt no longer installs fish by default)

## v2.2.2

- `dports update` checks images in parallel

## v2.2.1

- Fixed the `docker manifest inspect` reference syntax

## v2.2.0

### New features
- `dports update` subcommand with a whiptail/dialog checklist for pulling image updates

## v2.1.4

### CI/CD
- Release workflow treats already-published packages (HTTP 409) as success and no longer fails when a release does not exist yet (HTTP 404)

## v2.1.3

### Bug fixes
- Build and publish Debian packages for `all`, `amd64`, `arm64`, and `armhf`
- Make apt repository examples use host architecture (`dpkg --print-architecture`)
- Add troubleshooting guidance for apt architecture index notices

## v2.1.2

### CI/CD
- Added GitHub Actions release workflow (mirrors Forgejo Actions)

## v2.1.1

### Bug fixes
- Fixed version mismatch in `dports.fish` (was reporting `2.0.0`)
- Fixed undefined `UNCHECK` symbol in installer shell detection display
- Fixed temp file leak in installer when interrupted (Ctrl+C / signal)
- Fixed JSON output comma placement (commas now correctly trail each object)

## v2.1.0

### New features
- Debian package support: install via `apt` from the Forgejo package registry
- Forgejo Actions CI/CD workflow for automated `.deb` builds on tag push
- Makefile for local `.deb` package builds (`make deb`)
- Fish function installed system-wide via `/usr/share/fish/vendor_functions.d/`

## v2.0.0

### New features
- Interactive TUI installer using whiptail/dialog
- Automatic shell detection (Bash, Fish)
- Installation progress dialogs
- Automatic shell session activation after install
- Filtering options (`-p`, `-n`, `-i`)
- JSON output (`-j`)
- Quiet mode (`-q`)
- Verbose mode showing internal ports (`-v`)
- Color control (`-c`, `-C`)
- Support for stopped containers (`-a`)

### Improvements
- Fish shell tab completions
- Improved error handling and messages
- Fixed IPv6 address parsing
- Fallback to simple text menu when whiptail unavailable

## v1.0.0

- Initial release
- Basic port listing functionality
