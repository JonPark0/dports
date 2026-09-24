## v2.2.3

### Highlights
- `dports update` works on the containerd image store (the Docker Engine 29+ default). It used to report every image as outdated there. Updates are now detected by comparing `RepoDigests` with the registry: via `docker buildx` when available, otherwise via `docker manifest inspect` plus `jq`/`python3`. When there's no reliable answer, the status is `[?]` rather than a guess.
- `dports update` resolves images through each container's configured reference, so a container still running a replaced image is no longer listed as a bare image ID that cannot be pulled. Digest-pinned images show as `[PINNED]`.
- `dports -a` now shows the port bindings of stopped containers.
- Fish: update checks run in parallel, and completions ship in `completions/dports.fish`, so they work before the first run.
- Installer: fixed `--help` output, failed downloads in the dialog UI now show as errors, uninstall only removes files that define `dports` (and backs up dotfiles), and `--yes` is honoured.

### Notes
- Tag: `v2.2.3`
- The Debian package now suggests (rather than recommends) `fish`, and recommends `whiptail | dialog`.
