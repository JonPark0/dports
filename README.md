# dports

Show Docker container port mappings in a clean table, list the hostnames served through Cloudflare Tunnel, and update container images (pull and recreate) from one interactive screen.

## Features

- Port table for running (or all) containers, with optional internal ports
- Filters by port, container name and image name
- JSON and plain port-list output for scripts
- `dports -t`: Cloudflare Tunnel hostnames and the containers behind them
- `dports update`: check every running container's image against its registry, pull the ones you pick and recreate the Compose services that use them
- `dports -I` (experimental): browse ports and tunnel routes with search, container details, logs, restart and shell
- Bash, Fish and Zsh, with tab completion in Fish and Zsh

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

This installs `/usr/bin/dports` for every user, plus Fish and Zsh completions. Upgrade with `sudo apt upgrade dports`, remove with `sudo apt remove dports`.

### Installer script (per user)

```bash
bash <(curl -fsSL https://git.palnarium.com/jonpark0/dports/raw/branch/main/install.sh)
```

The installer detects Bash, Fish and Zsh, lets you choose which to set up (whiptail/dialog checklist, or a text menu), and downloads the files of the matching release tag.

| Command | Effect |
|---------|--------|
| `install.sh --all` | Install for every detected shell without asking |
| `install.sh --bash` / `--fish` / `--zsh` | Install for one shell only |
| `install.sh --simple` | Use the text menu instead of whiptail/dialog |
| `install.sh uninstall --all` | Remove the per-user installation |
| `install.sh uninstall --apt` | Also remove the Debian package (otherwise you are asked first) |

Files installed:

- Bash: `~/.bash_functions/dports`, loaded from `~/.bashrc`
- Fish: `~/.config/fish/functions/dports.fish`, `~/.config/fish/completions/dports.fish`, and `~/.local/share/dports/dports.bash`
- Zsh: `~/.local/share/dports/dports.zsh` (loaded from `~/.zshrc`), `~/.local/share/dports/zsh/_dports`, and `~/.local/share/dports/dports.bash`

dports is implemented once, in `dports.bash`. The Fish and Zsh functions run it with bash, so every feature works the same in all three shells.

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

Zsh (in `~/.zshrc`):

```zsh
source /path/to/dports/dports.zsh   # also loads completions/_dports next to it
```

The Fish and Zsh functions look for `dports.bash` in `$DPORTS_BASH`, `~/.local/share/dports/`, next to themselves, and as the `dports` command (Debian package).

Check the installation with `dports --version`.

## Usage

```
dports [OPTIONS]
dports -I [-t] [-a] [FILTERS]
dports update [--check | --yes] [--recreate]
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
| `-I`, `--interactive` | Browse in a full-screen view (experimental, see below) |
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

`dports update` runs as one full-screen flow, from checking to recreating, and leaves a summary in the terminal when you exit.

1. **Checking.** Every running container's image is compared with its registry, in parallel, with live status per image.
2. **Images.** Only images that have an update are selected at first.

```
 dports update                              2 update(s) · 2 selected · 1/5
──────────────────────────────────────────────────────────────────────────
      IMAGE                       STATUS      CONTAINERS
> [x] grafana/grafana:latest      update      grafana
  [ ] myapp:dev                   local       app
  [ ] nginx:latest                current     web, proxy
  [x] postgres:16                 update      db
  [ ] registry.example.com/api:1  unknown     api
──────────────────────────────────────────────────────────────────────────
 grafana/grafana:latest: The registry has a newer image
 Used by: grafana
 ↑↓ move  Space toggle  u updates  a all  n none  Enter pull  r recreate (1)  q quit
```

3. **Pulling.** The selected images are pulled one by one, each row showing its progress and result.
4. **Recreate.** Containers that now run an older image than their tag (because of this pull, or an earlier one) are listed per Compose service. `docker compose up -d --no-deps SERVICE` is run in the project's directory.

```
 dports update                              3 to recreate · 0 selected · 1/3
──────────────────────────────────────────────────────────────────────────
      SERVICE              STATE       CONTAINERS
> [ ] monitoring/grafana   outdated    grafana
      db                   manual      db
  [ ] site/web             recreated   web
──────────────────────────────────────────────────────────────────────────
 cd /srv/monitoring && docker compose up -d grafana
 Image: grafana/grafana:latest   Containers: grafana
 [ Recreate this ]  [ Recreate selected (0) ]  [ Recreate all ]  [ Done ]
```

| Screen | Keys |
|--------|------|
| Images | Up/Down, `k`/`j` move (PgUp/PgDn, Home/End jump); Space selects; `u`, `a`, `n` select updates, all, none; Enter pulls; `r` opens the recreate screen without pulling; `q` quits |
| Recreate | Enter recreates the service under the cursor; Space selects; `s` recreates the selected ones; `A` recreates all; Tab moves to the buttons (Left/Right, Enter); `q` is done |

Containers that are not managed by Docker Compose show as `manual`: dports cannot know their `docker run` options, so recreate them yourself.

| Status | Meaning |
|--------|---------|
| `update` | The registry has a newer image for the tag (selected by default) |
| `current` | The local image matches the registry |
| `pinned` | Referenced by digest, so pulling cannot change it |
| `local` | Built locally or loaded from a file: no registry digest, or the registry does not have the image |
| `unknown` | The registry could not be asked or gave no clear answer; the line under the list says why |

Without the full-screen view:

```bash
dports update --check              # only report; also what happens without a terminal
dports update --yes                # pull every image that has an update
dports update --yes --recreate     # ... and recreate every outdated Compose service
```

Updates are detected by comparing the digest recorded when the image was pulled (`RepoDigests`) with the registry, which works with both the classic and the containerd image store. `docker buildx` is used when available, otherwise `docker manifest inspect` parsed with `jq` or `python3`. At most 8 registries are queried at a time, each with a 30 second limit (`DPORTS_TIMEOUT`).

## Interactive browser (experimental)

`dports -I` shows the port table (and tunnel routes with `-t`) in a full-screen view. `-a`, `-p`, `-n` and `-i` work as usual.

```
 dports -I (experimental)                                   4/4 rows · refresh 5s
──────────────────────────────────────────────────────────────────────────
  KIND    PORT/HOST        CONTAINER   TARGET        IMAGE
> port    443              proxy       443/tcp       nginx:latest
  port    8080             web         80/tcp        nginx:latest
  tunnel  app.example.com  web         8080/http     nginx:latest
──────────────────────────────────────────────────────────────────────────
 proxy  running  since 2026-11-10 01:02:03 UTC  compose: site/proxy
 Ports: 443->443/tcp   Networks: site_default=172.18.0.4
 Image: nginx:latest
 ↑↓ move  / search  l logs  R restart  e shell  r refresh  q quit
```

| Key | Action |
|-----|--------|
| `/` | Search: rows are filtered as you type; Enter keeps the filter, Esc clears it |
| `l` | Logs of the container (last 500 lines, follows new output; `f` toggles follow) |
| `R` | Restart the container (asks first) |
| `e` | Open a shell in the container (bash, or sh); exit it to come back |
| `r` | Refresh now; the list also refreshes every 5 seconds (`DPORTS_REFRESH`, 0 turns it off) |
| `q`, Esc | Quit |

The detail lines show the container's state, health, Compose project, all its ports and networks, and whether it runs an older image than its tag.

## Requirements

- Docker CLI with access to the daemon
- Bash 4.3+ (Fish 3.0+ and Zsh 5+ front ends run it)
- `awk`, `sort`, `uniq`
- For `-t`: `curl` or `wget` to reach cloudflared's metrics server
- For `dports update`: `docker buildx` (recommended), or `jq` / `python3`; Docker Compose v2 (`docker compose`) to recreate services
- For the installer: `curl` or `wget`; `whiptail` or `dialog` for its menus (optional)

## Troubleshooting

**"Cannot connect to Docker daemon"**: start Docker (`sudo systemctl start docker`) or give your user access (`sudo usermod -aG docker $USER`, then log in again).

**apt prints "Skipping acquire of configured file ... binary-armhf"**: recreate the source line with `[arch=$(dpkg --print-architecture)]` as shown in the installation steps, then run `sudo apt update`.

**"command not found: dports" after the installer**: run `source ~/.bashrc` (Bash), `source ~/.zshrc` (Zsh), or open a new terminal. `type dports` (Bash, Zsh) or `functions dports` (Fish) shows whether it is loaded.

**Recreating a service fails with "The Compose project directory is not on this host"**: the container was started from another machine or a path that no longer exists (for example through a remote Docker context). Run `docker compose up -d` where the project lives.

**`dports -t` cannot read the ingress rules**: there is no config file in the container and the metrics server is not reachable. This is expected for token tunnels on Docker Desktop, rootless Docker or a remote daemon. On native Linux, install `curl` or `wget` and make sure `--metrics` is not bound to `localhost`.

**`dports update` shows `unknown`**: the line under the checklist gives the reason. Usually a private registry without `docker login <registry>`, the Docker Hub rate limit for anonymous requests (`docker login` raises it), or a multi-platform image on the containerd store without `docker buildx`.

## Development

```bash
make check   # syntax checks (bash; fish, zsh, shellcheck when installed), version consistency
make test    # tests against a fake docker CLI: update logic (bash), full-screen views and
             # shell front ends in a pseudo-terminal (python3, zsh, fish when installed)
make deb     # build dports_<version>_all.deb
```

Pushing a `vX.Y.Z` tag runs the Forgejo release workflow: it builds the packages, uploads them to the apt repository and creates the release. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).

Author: yeochoon ([Forgejo](https://git.palnarium.com/JonPark0))
