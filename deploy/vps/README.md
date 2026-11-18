# deploy/vps: the tutor on a server

asterism-tutor next to an Asterism console (its `deploy/vps`), answering the
devices that have the console's role `tutor` through the console's router.
**The steps are in [docs/install.md](../../docs/install.md).**

| File | |
|---|---|
| `docker-compose.yml` | the tutor (project `asterism-tutor`) on the published image `ghcr.io/ruby-asterism/asterism-tutor:<version>`: the console's `router` network by name, its own `state` volume, `credentials/` read-only, a healthcheck (`asterism-tutor status`) |
| `docker-compose.build.yml` | to build the image here instead of pulling it |
| `Dockerfile` | the image (the CI builds it for each tag `v<version>`) |
| `env.example` | the settings, copied to `.env` (never committed; the LLM key goes there) |
| `credentials/` | the tutor's own `.tar` from the console (never committed) |
| `update.sh` | pull a version's image and restart in one command (`--build` builds it here); `--when-idle` restarts only when no request is being worked on |

The tutor's volume is not in the console's daily backup (the records stay in
this volume only).
