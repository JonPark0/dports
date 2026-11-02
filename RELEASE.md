## v2.4.1

### Fixes
- `dports update` showed locally built images as `unknown` on the containerd image store (the Docker Engine 29+ default). Images that their registry does not have, such as a bare name that is not on Docker Hub, are now `local`.
- The line under the checklist now says why a registry query failed: Docker Hub rate limit, login needed (with the registry name), registry unreachable, or timeout.

### Notes
- Tag: `v2.4.1`
- See CHANGELOG.md for v2.4.0 (new full-screen checklist for `dports update`).
