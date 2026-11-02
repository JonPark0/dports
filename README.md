# dports

A command-line utility to display Docker container port mappings in a clean, formatted table.

![Version](https://img.shields.io/badge/version-2.4.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Shell](https://img.shields.io/badge/shell-bash%20%7C%20fish-orange.svg)

## Features

- 📋 Clean tabular output of Docker container ports
- 🎨 Colored output with automatic terminal detection
- 🔍 Filter by port, container name, or image name
- 📊 Verbose mode showing internal port mappings
- 📤 JSON output for scripting and automation
- 🔄 `dports update`: check running containers' images for updates and pull them
- ☁️ `dports -t`: show hostnames served through Cloudflare Tunnel (cloudflared) and the containers behind them
- 🐚 Supports both Bash and Fish shells
- ⚡ Tab completion support (Fish)
- 🖥️ Interactive TUI installer with whiptail

## Installation

### APT Package (Debian/Ubuntu — Recommended)

Install via the Forgejo package registry:

```bash
# 1. Add the repository GPG key
curl -sS "https://git.palnarium.com/api/packages/jonpark0/debian/repository.key" \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/forgejo-dports.gpg > /dev/null

# 2. Add the repository
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/forgejo-dports.gpg] https://git.palnarium.com/api/packages/jonpark0/debian stable main" \
  | sudo tee /etc/apt/sources.list.d/dports.list

# 3. Install
sudo apt update && sudo apt install dports
```

After installation, `dports` is available system-wide as a standalone command. No shell configuration needed.

To upgrade to a newer version:

```bash
sudo apt update && sudo apt upgrade dports
```

To remove:

```bash
sudo apt remove dports
```

### Quick Install (Shell function)

Run the interactive installer:

```bash
# Download and run interactive installer
bash <(curl -fsSL https://git.palnarium.com/jonpark0/dports/raw/branch/main/install.sh)
```

The installer will:
1. **Auto-detect** available shells (Bash, Fish)
2. **Show interactive checklist** to choose which shells to install (via whiptail)
3. **Install** the appropriate files automatically
4. **Offer to activate** dports in your current session

#### Interactive UI (whiptail)

```
┌───────────────dports Installer───────────────┐
│ Select shells to install:                    │
│                                              │
│ Use SPACE to toggle, ENTER to confirm        │
│                                              │
│    [*] bash    Bash 5.2                      │
│    [*] fish    Fish 3.6.1                    │
│                                              │
│          <OK>            <Cancel>            │
└──────────────────────────────────────────────┘
```

**Keyboard controls:**
- `↑` `↓` — Navigate between options
- `Space` — Toggle selection on/off
- `Tab` — Switch between list and OK/Cancel buttons
- `Enter` — Confirm selection
- `Esc` — Cancel installation

#### Installation Progress

The installer shows progress dialogs during installation:

```
┌────────────Installing Bash───────────────────┐
│ Installing dports for Bash...                │
│                                              │
│ ██████████████████░░░░░░░░░░░░░░░░░░░░  50%  │
└──────────────────────────────────────────────┘
```

#### Automatic Shell Activation

After installation completes:

- **Fish shell**: dports is available immediately (Fish auto-loads functions)
- **Bash shell**: The installer offers to start a new shell session with dports enabled

```
┌─────────────Apply Changes────────────────────┐
│                                              │
│ Would you like to start a new shell session  │
│ with dports enabled?                         │
│                                              │
│ Select 'Yes' to start a new bash session.    │
│ Select 'No' to manually run: source ~/.bashrc│
│                                              │
│          <Yes>            <No>               │
└──────────────────────────────────────────────┘
```

### Non-Interactive Install

```bash
# Install for all detected shells
./install.sh --all

# Install for specific shell only
./install.sh --bash
./install.sh --fish

# Use simple text menu (if whiptail unavailable)
./install.sh --simple

# Uninstall
./install.sh uninstall --all
```

### Manual Installation

#### Bash

1. Create the functions directory (if it doesn't exist):
   ```bash
   mkdir -p ~/.bash_functions
   ```

2. Copy `dports.bash` to the functions directory:
   ```bash
   cp dports.bash ~/.bash_functions/dports
   ```

3. Add the following to your `~/.bashrc` (if not already present):
   ```bash
   # Load all functions from ~/.bash_functions
   if [ -d ~/.bash_functions ]; then
       for func in ~/.bash_functions/*; do
           . "$func"
       done
   fi
   ```

4. Reload your shell:
   ```bash
   source ~/.bashrc
   ```

#### Fish

1. Copy `dports.fish` to Fish functions directory, and the completions to the completions directory:
   ```fish
   cp dports.fish ~/.config/fish/functions/
   cp completions/dports.fish ~/.config/fish/completions/
   ```

2. The function is immediately available (Fish auto-loads functions from this directory).

### Verify Installation

```bash
dports --version
# Output: dports version 2.4.0
```

## Usage

```
dports [OPTIONS]
dports update [--check | --yes]
```

### Options

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-v` | `--verbose` | Show detailed port mapping (external → internal) |
| `-a` | `--all` | Include stopped containers |
| `-p` | `--port PORT` | Filter by port number (exact match) |
| `-n` | `--name NAME` | Filter by container name (partial match, case-insensitive) |
| `-i` | `--image IMAGE` | Filter by image name (partial match, case-insensitive) |
| `-t` | `--tunnel` | Also show Cloudflare Tunnel routes (see below) |
| `-c` | `--color` | Force color output (even when piped) |
| `-C` | `--no-color` | Disable color output |
| `-q` | `--quiet` | Only show port numbers (one per line) |
| `-j` | `--json` | Output in JSON format |
| `-h` | `--help` | Show help message |
| `-V` | `--version` | Show version information |

## Examples

### Basic Usage

```bash
# List all running containers with exposed ports
$ dports
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
80        nginx-proxy                   nginx:latest
443       nginx-proxy                   nginx:latest
3000      grafana                       grafana/grafana:latest
5432      postgres-db                   postgres:16
8080      web-app                       myapp:v1.2.0
```

### Verbose Mode

```bash
# Show internal port mappings
$ dports -v
PORT      NAME                          INTERNAL         IMAGE
────────  ────────────────────────────  ───────────────  ────────────────────────
80        nginx-proxy                   80/tcp           nginx:latest
443       nginx-proxy                   443/tcp          nginx:latest
3000      grafana                       3000/tcp         grafana/grafana:latest
5432      postgres-db                   5432/tcp         postgres:16
8080      web-app                       8080/tcp         myapp:v1.2.0
```

### Filtering

```bash
# Filter by port number
$ dports -p 8080
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
8080      web-app                       myapp:v1.2.0

# Filter by container name (partial match)
$ dports -n nginx
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
80        nginx-proxy                   nginx:latest
443       nginx-proxy                   nginx:latest

# Filter by image name
$ dports -i postgres
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
5432      postgres-db                   postgres:16

# Combine multiple filters (AND logic)
$ dports -n web -p 80
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
80        web-frontend                  nginx:latest
```

### Include Stopped Containers

```bash
$ dports -a
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
80        nginx-proxy                   nginx:latest
3000      grafana                       grafana/grafana:latest
8080      old-app                       myapp:v1.0.0
```

For stopped containers the ports are the configured bindings (`docker ps` does not show ports for containers that are not running).

### Scripting and Automation

```bash
# Get only port numbers (quiet mode)
$ dports -q
80
443
3000
5432
8080

# JSON output for parsing
$ dports -j
[
  {"port": "80", "name": "nginx-proxy", "internal": "80/tcp", "image": "nginx:latest"},
  {"port": "443", "name": "nginx-proxy", "internal": "443/tcp", "image": "nginx:latest"},
  {"port": "3000", "name": "grafana", "internal": "3000/tcp", "image": "grafana/grafana:latest"}
]

# Use with jq for advanced filtering
$ dports -j | jq '.[] | select(.port == "80")'

# Pipe to other commands
$ dports -q | xargs -I{} echo "Port {} is in use"

# Check if a specific port is used
$ dports -q | grep -q "^8080$" && echo "Port 8080 is in use"
```

### Color Control

```bash
# Force colors when piping (e.g., to `less -R`)
$ dports -c | less -R

# Disable colors for clean text output
$ dports -C > ports.txt
```

### Cloudflare Tunnel Routes

Containers published through [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) have no host port, so they are missing from the port table. `-t` adds a second table that maps each tunnel hostname to the container behind it:

```bash
$ dports -t
PORT      NAME                          IMAGE
────────  ────────────────────────────  ────────────────────────
443       nginx-proxy                   nginx:latest

HOSTNAME                          NAME                      TARGET        IMAGE
────────────────────────────────  ────────────────────────  ────────────  ────────────────────────
api.example.com ^/v1              backend                   3000/http     myapi:1.4
app.example.com                   web                       8080/http     myapp:v1.2.0
nas.example.com                   (192.168.1.50)            5000/http     -
ssh.example.com                   bastion                   22/ssh        linuxserver/openssh-server
```

- `-v` shows the full service URL and the cloudflared container instead of `TARGET`.
- `-t -j` and `-t -q` print **only** the tunnel routes (JSON objects with `hostname`, `path`, `name`, `image`, `port`, `protocol`, `service`, `tunnel`; or hostnames), so each output stays one kind of record.
- `-n`, `-i` and `-p` filter by the target container's name, image and port.
- A name in parentheses, such as `(192.168.1.50)`, is a target that is not a local container.
- A hostname of `*` is a catch-all rule, or a quick tunnel whose `trycloudflare.com` hostname is unknown.

How it works: dports finds running `cloudflared` containers and reads their ingress rules from:

1. cloudflared's metrics server (`/config` on port 20241–20245, or `--metrics`/`TUNNEL_METRICS`). This covers **dashboard-managed (token) tunnels** as well as config-file tunnels. It needs a native Linux Docker host (not Docker Desktop, rootless Docker or a remote daemon) and `curl` or `wget`.
2. The tunnel's config file inside the container (`--config`, or `/etc/cloudflared/config.yml` and the other default locations), read with `docker cp`.
3. A `--url` / `TUNNEL_URL` origin (quick tunnels).

Each rule's service (`http://web:8080`) is matched to a container by name, compose service, network alias, hostname or IP on a network shared with cloudflared. `localhost` means the container cloudflared shares a network namespace with, or a published host port when cloudflared uses `network_mode: host`. `host.docker.internal` means a published host port.

### Checking for Image Updates

`dports update` checks the images of all running containers against their registries (in parallel, with a live counter), then opens a full-screen checklist to pick which ones to pull. Only images with an update are selected at first.

```
 dports update                              2 update(s) · 2 selected · 1/5
──────────────────────────────────────────────────────────────────────────
      IMAGE                       STATUS   CONTAINERS
> [x] grafana/grafana:latest      update   grafana
  [ ] myapp:dev                   local    app
  [ ] nginx:latest                current  web, proxy
  [x] postgres:16                 update   db
  [ ] registry.example.com/api:1  unknown  api

──────────────────────────────────────────────────────────────────────────
 grafana/grafana:latest: The registry has a newer image
 Used by: grafana
 ↑↓ move  Space toggle  u updates  a all  n none  Enter pull  q quit
```

| Key | Action |
|-----|--------|
| `↑`/`↓`, `k`/`j` | Move (`PgUp`/`PgDn`, `Home`/`End` jump) |
| `Space` | Toggle the image under the cursor |
| `u` / `a` / `n` | Select images with updates / all / none |
| `Enter` | Pull the selected images |
| `q`, `Esc` | Quit without pulling |

| Status | Meaning |
|--------|---------|
| `update` | The registry has a newer image for the tag (selected by default) |
| `current` | The local image matches the registry |
| `pinned` | Referenced by digest; pulling cannot change it |
| `local` | No registry digest: built locally or loaded from a file |
| `unknown` | Private registry without login, rate limit, no network, or no way to compare (the line under the list says why) |

```bash
dports update --check   # report only, pull nothing (also the default without a terminal)
dports update --yes     # pull every image with an update, without asking
```

Pulling only updates the local image. After pulling, dports prints the command that recreates the affected containers, for example `cd /srv/site && docker compose up -d web proxy` for Compose projects.

Registry queries time out after 30 seconds (`DPORTS_TIMEOUT` changes this). In Fish, `dports update` runs the same implementation from `dports.bash`, so Bash must be installed.

How updates are detected: the digest recorded when the image was pulled (`RepoDigests`) is compared with the registry. This works with both the classic and the containerd image store (the default since Docker Engine 29). `docker buildx` is used when available; otherwise dports falls back to `docker manifest inspect` parsed with `jq` or `python3`. Without buildx, multi-platform images on the containerd store show `?`.

## Output Columns

| Column | Description |
|--------|-------------|
| `PORT` | The host (external) port that is exposed |
| `NAME` | The Docker container name |
| `INTERNAL` | The internal container port with protocol (verbose mode only) |
| `IMAGE` | The Docker image name and tag |

## Requirements

### For dports command
- Docker Engine installed and running
- Bash 4.3+ or Fish 3.0+ (`dports update` always needs Bash)
- Standard Unix utilities: `awk`, `sort`, `uniq`

### For `dports -t` (optional)
- `curl` or `wget` to read ingress rules from cloudflared's metrics server (native Linux Docker only)

### For `dports update` (optional)
- `docker buildx` (recommended; included with Docker Desktop and `docker-buildx-plugin`)
- `jq` or `python3` (fallback when buildx is missing)

### For installer (optional)
- `whiptail` or `dialog` — For interactive TUI menus (falls back to simple text menu if unavailable)
- `curl` or `wget` — For downloading files (only needed for remote installation)

Most Linux distributions include `whiptail` by default. If not available:

```bash
# Debian/Ubuntu
sudo apt install whiptail

# Fedora/RHEL
sudo dnf install newt

# Arch Linux
sudo pacman -S libnewt
```

## Troubleshooting

### "Cannot connect to Docker daemon"

Ensure Docker is running and you have permission to access it:

```bash
# Check if Docker is running
sudo systemctl status docker

# Add yourself to the docker group (logout/login required)
sudo usermod -aG docker $USER
```

### "Skipping acquire ... binary-armhf/arm64/Packages"

If your system has multiple foreign architectures enabled, apt may try to fetch indexes your source line does not target.
Re-create the dports source list entry with your host architecture:

```bash
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/forgejo-dports.gpg] https://git.palnarium.com/api/packages/jonpark0/debian stable main" \
  | sudo tee /etc/apt/sources.list.d/dports.list

sudo apt update
```

### "Command not found: dports"

Ensure the function file is properly sourced:

```bash
# Bash: Reload your configuration
source ~/.bashrc

# Bash: Check if function is loaded
type dports

# Fish: Check if function exists (should work immediately)
functions dports
```

### Colors not displaying

Some terminals may not support ANSI colors. Try:

```bash
# Force colors
dports -c

# Or check your TERM variable
echo $TERM
```

### `dports -t` says it cannot read the ingress rules

dports could not find a config file in the cloudflared container, and could not reach its metrics server. This is expected for dashboard-managed (token) tunnels on Docker Desktop, rootless Docker, or a remote Docker host. On a native Linux host, check that `curl` or `wget` is installed and that `--metrics` is not bound to `localhost`.

### `dports update` shows `unknown` for an image

The image could not be compared with its registry; the line under the checklist says why. Common causes:

- The registry is private and you are not logged in (`docker login`)
- Docker Hub rate limits for anonymous pulls (`docker login` raises the limit)
- The containerd image store is used and `docker buildx` is not installed

### Installer shows text menu instead of graphical UI

The installer requires `whiptail` or `dialog` for the graphical TUI. Install it:

```bash
# Debian/Ubuntu
sudo apt install whiptail
```

Or use the simple text menu with `--simple` flag:

```bash
./install.sh --simple
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Changelog

### v2.4.0

**New Features:**
- `dports update` has its own full-screen checklist instead of whiptail/dialog: shows the containers using each image and why a status is unknown, scrolls, follows terminal resizes, and adds keys to select updates/all/none
- New statuses: `local` (built locally) is separate from `unknown`; neither is selected by default any more
- `dports update --check` (report only) and `--yes` (pull every update); without a terminal, `update` only reports
- After pulling, dports prints the `docker compose up -d` command that recreates the affected containers
- Live progress while checking, at most 8 registry queries at a time, each with a 30 s timeout (`DPORTS_TIMEOUT`)

**Bug Fixes:**
- 32-bit ARM hosts without buildx compared against the wrong arm variant and always reported an update
- `-C/--no-color` was ignored by `dports update`, and options after `update` were silently dropped
- `make deb` failed (`control directory has bad permissions 777`) when run with umask 000, as in some CI containers

**Changes:**
- Fish runs `dports update` from `dports.bash` (one implementation); the installer puts a copy in `~/.local/share/dports/`
- The Debian package no longer recommends whiptail and needs Bash 4.3+
- `make test` runs the update tests against a fake docker CLI

### v2.3.0

**New Features:**
- `-t/--tunnel`: list Cloudflare Tunnel hostnames and the containers they route to, read from cloudflared's metrics server (including dashboard-managed tunnels) or its config file

**Bug Fixes:**
- `dports update` reported every image as outdated on the containerd image store (the Docker Engine 29+ default); updates are now detected from `RepoDigests` and work on both image stores
- `dports update` no longer lists containers still running an old image as bare image IDs, skips digest-pinned images, and no longer prints job-control noise (`[1] 1234`) when run as a shell function
- Removed `eval` of dialog output and the traps that overwrote the calling shell's own traps
- Fish: update checks now really run in parallel, and completions are shipped separately so they work before the first `dports` run
- `-a/--all` now shows the port bindings of stopped containers (they were never displayed)
- Installer: `--help` printed raw escape codes; the dialog UI reported success even when the download failed; uninstall deleted any file in `~/.bash_functions` that merely mentioned "dports"; `--yes` was ignored
- Debian package: `fish` moved from Recommends to Suggests (apt no longer installs fish by default)

### v2.2.2

- `dports update` checks images in parallel

### v2.2.1

- Fixed the `docker manifest inspect` reference syntax

### v2.2.0

**New Features:**
- `dports update` subcommand with a whiptail/dialog checklist for pulling image updates

### v2.1.4

**CI/CD:**
- Release workflow treats already-published packages (HTTP 409) as success and no longer fails when a release does not exist yet (HTTP 404)

### v2.1.3

**Bug Fixes:**
- Build and publish Debian packages for `all`, `amd64`, `arm64`, and `armhf`
- Make apt repository examples use host architecture (`dpkg --print-architecture`)
- Add troubleshooting guidance for apt architecture index notices

### v2.1.2

**CI/CD:**
- Added GitHub Actions release workflow (mirrors Forgejo Actions)

### v2.1.1

**Bug Fixes:**
- Fixed version mismatch in `dports.fish` (was reporting `2.0.0`)
- Fixed undefined `UNCHECK` symbol in installer shell detection display
- Fixed temp file leak in installer when interrupted (Ctrl+C / signal)
- Fixed JSON output comma placement (commas now correctly trail each object)

### v2.1.0

**New Features:**
- Debian package support — install via `apt` from the Forgejo package registry
- Forgejo Actions CI/CD workflow for automated `.deb` builds on tag push
- Makefile for local `.deb` package builds (`make deb`)
- Fish function installed system-wide via `/usr/share/fish/vendor_functions.d/`

### v2.0.0

**New Features:**
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

**Improvements:**
- Fish shell tab completions
- Improved error handling and messages
- Fixed IPv6 address parsing
- Fallback to simple text menu when whiptail unavailable

### v1.0.0

- Initial release
- Basic port listing functionality

## Author

**yeochoon** - [Forgejo](https://git.palnarium.com/JonPark0)

## Acknowledgments

- Inspired by the need for a quick way to see Docker port mappings
- Thanks to the Docker and shell scripting communities
