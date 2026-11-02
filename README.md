# dports

Show Docker container port mappings in a clean table, list the hostnames served through Cloudflare Tunnel, and update container images from an interactive checklist.

## Features

- Port table for running (or all) containers, with optional internal ports
- Filters by port, container name and image name
- JSON and plain port-list output for scripts
- `dports -t`: Cloudflare Tunnel hostnames and the containers behind them
- `dports update`: check every running container's image against its registry and pull the ones you pick
- Bash and Fish, with Fish tab completion

## Installation

### APT package (Debian/Ubuntu, recommended)

```bash
# 1. Add the repository key
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

This installs `/usr/bin/dports` for every user, plus the Fish function and completions. Upgrade with `sudo apt upgrade dports`, remove with `sudo apt remove dports`.

### Installer script (per user)

```bash
bash <(curl -fsSL https://git.palnarium.com/jonpark0/dports/raw/branch/main/install.sh)
```

The installer detects Bash and Fish, lets you choose which to set up (whiptail/dialog checklist, or a text menu), and downloads the files of the matching release tag.

| Command | Effect |
|---------|--------|
| `install.sh --all` | Install for every detected shell without asking |
| `install.sh --bash` / `--fish` | Install for one shell only |
| `install.sh --simple` | Use the text menu instead of whiptail/dialog |
| `install.sh uninstall --all` | Remove the per-user installation |
| `install.sh uninstall --apt` | Also remove the Debian package (otherwise you are asked first) |

Files installed:

- Bash: `~/.bash_functions/dports`, loaded from `~/.bashrc`
- Fish: `~/.config/fish/functions/dports.fish`, `~/.config/fish/completions/dports.fish`, and `~/.local/share/dports/dports.bash` (used by `dports update`)

### Manual installation

Bash:

```bash
mkdir -p ~/.bash_functions
cp dports.bash ~/.bash_functions/dports
# then add to ~/.bashrc:
for f in ~/.bash_functions/*; do [ -f "$f" ] && . "$f"; done
```

Fish:

```fish
cp dports.fish ~/.config/fish/functions/
cp completions/dports.fish ~/.config/fish/completions/
```

`dports update` in Fish runs `dports.bash`; keep a copy next to `dports.fish`, in `~/.local/share/dports/`, or set `DPORTS_BASH` to its path.

Check the installation with `dports --version`.

## Usage

```
dports [OPTIONS]
dports update [--check | --yes]
```

| Option | Description |
|--------|-------------|
| `-v`, `--verbose` | Also show the internal (container) port |
| `-a`, `--all` | Include stopped containers |
| `-p`, `--port PORT` | Only this host port (exact match) |
| `-n`, `--name NAME` | Container name contains NAME (case-insensitive) |
| `-i`, `--image IMAGE` | Image name contains IMAGE (case-insensitive) |
| `-t`, `--tunnel` | Also show Cloudflare Tunnel routes |
| `-c`, `--color` / `-C`, `--no-color` | Force or disable colors |
| `-q`, `--quiet` | Print host ports only, one per line |
| `-j`, `--json` | Print JSON |
| `-h`, `--help` / `-V`, `--version` | Help / version |

Filters can be combined; all of them must match.

## Examples

```
$ dports -v
PORT      NAME                          INTERNAL         IMAGE
────────  ────────────────────────────  ───────────────  ────────────────────────
80        nginx-proxy                   80/tcp           nginx:latest
443       nginx-proxy                   443/tcp          nginx:latest
3000      grafana                       3000/tcp         grafana/grafana:latest
5432      postgres-db                   5432/tcp         postgres:16
```

```bash
dports -p 8080                  # who uses host port 8080
dports -n web -i nginx          # name contains "web" and image contains "nginx"
dports -a                       # include stopped containers (their configured bindings)
dports -q | grep -qx 8080 && echo "8080 is taken"
dports -j | jq '.[] | select(.port == "80")'
dports -c | less -R             # keep colors in a pager
```

JSON output is an array of `{"port", "name", "internal", "image"}` objects.

## Cloudflare Tunnel routes

Containers published through [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) have no host port, so the port table cannot show them. `-t` adds a table that maps each tunnel hostname to the container behind it:

```
$ dports -t
...
HOSTNAME                          NAME                      TARGET        IMAGE
────────────────────────────────  ────────────────────────  ────────────  ────────────────────────
api.example.com ^/v1              backend                   3000/http     myapi:1.4
app.example.com                   web                       8080/http     myapp:v1.2.0
nas.example.com                   (192.168.1.50)            5000/http     -
```

- `-v` shows the full service URL and the cloudflared container instead of `TARGET`.
- `-t -j` and `-t -q` print only the tunnel routes (JSON with `hostname`, `path`, `name`, `image`, `port`, `protocol`, `service`, `tunnel`; or one hostname per line).
- `-n`, `-i` and `-p` filter by the target container's name, image and port.
- A name in parentheses is a target that is not a local container. A hostname of `*` is a catch-all rule, or a quick tunnel whose hostname is unknown.

dports finds running `cloudflared` containers and reads their ingress rules from, in order:

1. The metrics server (`/config` on ports 20241-20245, or `--metrics` / `TUNNEL_METRICS`). This also covers dashboard-managed (token) tunnels, but needs a native Linux Docker host (not Docker Desktop, rootless Docker or a remote daemon) and `curl` or `wget`.
2. The config file inside the container (`--config`, or `/etc/cloudflared/config.yml` and the other default locations), read with `docker cp`.
3. A `--url` / `TUNNEL_URL` origin (quick tunnels).

A rule's service (for example `http://web:8080`) is matched to a container by name, Compose service, network alias, hostname or IP on a network shared with cloudflared. `localhost` means the container that shares cloudflared's network namespace, or a published port when cloudflared uses host networking; `host.docker.internal` means a published port.

## Image updates

`dports update` checks the images of all running containers against their registries, then opens a full-screen checklist. Only images that have an update are selected at first.

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
| Up/Down, `k`/`j` | Move (PgUp/PgDn, Home/End jump) |
| Space | Select or clear the image under the cursor |
| `u`, `a`, `n` | Select images with updates, all, none |
| Enter | Pull the selected images |
| `q`, Esc | Quit without pulling |

| Status | Meaning |
|--------|---------|
| `update` | The registry has a newer image for the tag (selected by default) |
| `current` | The local image matches the registry |
| `pinned` | Referenced by digest, so pulling cannot change it |
| `local` | Built locally or loaded from a file: no registry digest, or the registry does not have the image |
| `unknown` | The registry could not be asked or gave no clear answer; the line under the list says why |

```bash
dports update --check   # only report; also what happens without a terminal
dports update --yes     # pull every image that has an update, without asking
```

Pulling only replaces the local image. Afterwards dports prints the command that recreates the affected containers, such as `cd /srv/site && docker compose up -d web proxy`.

Updates are detected by comparing the digest recorded when the image was pulled (`RepoDigests`) with the registry, which works with both the classic and the containerd image store. `docker buildx` is used when available, otherwise `docker manifest inspect` parsed with `jq` or `python3`. At most 8 registries are queried at a time, each with a 30 second limit (`DPORTS_TIMEOUT`).

## Requirements

- Docker CLI with access to the daemon
- Bash 4.3+ or Fish 3.0+ (`dports update` always runs in Bash)
- `awk`, `sort`, `uniq`
- For `-t`: `curl` or `wget` to reach cloudflared's metrics server
- For `dports update`: `docker buildx` (recommended), or `jq` / `python3`
- For the installer: `curl` or `wget`; `whiptail` or `dialog` for its menus (optional)

## Troubleshooting

**"Cannot connect to Docker daemon"**: start Docker (`sudo systemctl start docker`) or give your user access (`sudo usermod -aG docker $USER`, then log in again).

**apt prints "Skipping acquire of configured file ... binary-armhf"**: recreate the source line with `[arch=$(dpkg --print-architecture)]` as shown in the installation steps, then run `sudo apt update`.

**"command not found: dports" after the installer**: run `source ~/.bashrc` (Bash) or open a new terminal. `type dports` (Bash) or `functions dports` (Fish) shows whether it is loaded.

**`dports -t` cannot read the ingress rules**: there is no config file in the container and the metrics server is not reachable. This is expected for token tunnels on Docker Desktop, rootless Docker or a remote daemon. On native Linux, install `curl` or `wget` and make sure `--metrics` is not bound to `localhost`.

**`dports update` shows `unknown`**: the line under the checklist gives the reason. Usually a private registry without `docker login <registry>`, the Docker Hub rate limit for anonymous requests (`docker login` raises it), or a multi-platform image on the containerd store without `docker buildx`.

## Development

```bash
make check   # syntax checks, shellcheck/fish when installed, version consistency
make test    # dports update tests against a fake docker CLI (tests/)
make deb     # build dports_<version>_all.deb
```

Pushing a `vX.Y.Z` tag runs the Forgejo release workflow: it builds the packages, uploads them to the apt repository and creates the release. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).

Author: yeochoon ([Forgejo](https://git.palnarium.com/JonPark0))
