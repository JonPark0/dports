## v2.2.0

### Highlights
- Add `dports update` subcommand: checks running container images for newer versions and offers an interactive whiptail/dialog TUI checklist to select and pull updates.
- Update check compares local image config digest against the remote manifest (handles both single-arch and multi-arch manifest lists). Falls back gracefully to `[?]` for private registries or offline environments.
- TUI pre-selects images with updates available; up-to-date images are unchecked by default.
- Plain-text numbered fallback for environments without whiptail/dialog.
- Post-pull summary shows updated, already-current, and failed counts.

### Notes
- Tag: `v2.2.0`
- Main branch release with Forgejo/GitHub workflows.
