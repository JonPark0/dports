## v2.6.0

### Highlights
- Podman, Incus and LXD support next to Docker, in one table with an ENGINE column when more than one engine is in use (JSON gains an `engine` field).
- Incus and LXD: ports come from proxy devices and network-forward rules, mapped to the instance they reach. `-t` resolves tunnel routes to Incus instances, and `-I` shows their details, console log, restart and shell.
- Podman: `dports update` checks images with skopeo (or `podman manifest inspect`) and recreates Compose services (`podman compose up -d --force-recreate`) and systemd-managed containers (Quadlet) by restarting their unit.
- Choose the engines in `~/.config/dports/config` or `/etc/dports.conf` (`engines = docker,incus`), with `DPORTS_ENGINES`, or `--engine`. Without configuration they are auto-detected from their command and socket or storage, without contacting any daemon. `dports engines` shows the result.

### Notes
- Tag: `v2.6.0`
- Incus and LXD need `jq` or `python3` (to read their API). They have no registry images, so `dports update` leaves them out.
- Checked against real Podman 4.9 with podman-compose and Incus 6.0, plus automated tests with fake CLIs. LXD and systemd units are covered by the tests only.
