# dports

A command-line utility to display Docker container port mappings in a clean, formatted table.

![Version](https://img.shields.io/badge/version-2.1.1-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Shell](https://img.shields.io/badge/shell-bash%20%7C%20fish-orange.svg)

## Features

- 📋 Clean tabular output of Docker container ports
- 🎨 Colored output with automatic terminal detection
- 🔍 Filter by port, container name, or image name
- 📊 Verbose mode showing internal port mappings
- 📤 JSON output for scripting and automation
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
echo "deb [signed-by=/usr/share/keyrings/forgejo-dports.gpg] https://git.palnarium.com/api/packages/jonpark0/debian stable main" \
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

1. Copy `dports.fish` to Fish functions directory:
   ```fish
   cp dports.fish ~/.config/fish/functions/
   ```

2. The function is immediately available (Fish auto-loads functions from this directory).

### Verify Installation

```bash
dports --version
# Output: dports version 2.1.0
```

## Usage

```
dports [OPTIONS]
```

### Options

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-v` | `--verbose` | Show detailed port mapping (external → internal) |
| `-a` | `--all` | Include stopped containers |
| `-p` | `--port PORT` | Filter by port number (exact match) |
| `-n` | `--name NAME` | Filter by container name (partial match, case-insensitive) |
| `-i` | `--image IMAGE` | Filter by image name (partial match, case-insensitive) |
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
8080      old-app (stopped)             myapp:v1.0.0
```

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
- Bash 4.0+ or Fish 3.0+
- Standard Unix utilities: `awk`, `sort`, `uniq`

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