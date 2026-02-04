# dports

A command-line utility to display Docker container port mappings in a clean, formatted table.

![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)
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

## Installation

### Quick Install (Recommended)

Run the interactive installer:

```bash
# Download and run interactive installer
bash <(curl -fsSL https://raw.githubusercontent.com/yeochoon/dports/main/install.sh)
```

The installer will:
1. **Auto-detect** available shells (Bash, Fish)
2. **Show checkbox selection** to choose which shells to install
3. **Install** the appropriate files automatically

```
╭─────────────────────────────────────────╮
│  Select shells to install:              │
│  (Space=toggle, Enter=confirm, a=all)   │
│                                         │
│ ❯ [✔] Bash 5.2                          │
│   [✔] Fish 3.6.1                        │
│                                         │
╰─────────────────────────────────────────╯
```

**Keyboard controls:**
- `↑` `↓` or `j` `k` — Navigate
- `Space` — Toggle selection
- `a` — Select/deselect all
- `Enter` — Confirm and install
- `q` — Quit

### Non-Interactive Install

```bash
# Install for all detected shells
./install.sh --all

# Install for specific shell only
./install.sh --bash
./install.sh --fish

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

2. The function is immediately available (no reload needed).

### Verify Installation

```bash
dports --version
# Output: dports version 2.0.0
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

- Docker Engine installed and running
- Bash 4.0+ or Fish 3.0+
- Standard Unix utilities: `awk`, `sort`, `uniq`

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
# Bash: Check if function is loaded
type dports

# Fish: Check if function exists
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

### v2.0.0

- Added filtering options (`-p`, `-n`, `-i`)
- Added JSON output (`-j`)
- Added quiet mode (`-q`)
- Added verbose mode showing internal ports (`-v`)
- Added color control (`-c`, `-C`)
- Added support for stopped containers (`-a`)
- Improved error handling and messages
- Added Fish shell tab completions
- Fixed IPv6 address parsing

### v1.0.0

- Initial release
- Basic port listing functionality

## Author

**yeochoon** - [GitHub](https://github.com/yeochoon)

## Acknowledgments

- Inspired by the need for a quick way to see Docker port mappings
- Thanks to the Docker and shell scripting communities
