# dynamic-radicle-docker

A Docker image that runs a [Radicle](https://radicle.xyz) seed node and/or HTTP
daemon, downloading the requested version at startup. No version is baked into
the image — you specify it with an environment variable, making upgrades and
downgrades as simple as changing one line.

## How it works

The image contains no Radicle binaries. On first start, the entrypoint
downloads the requested release from `files.radicle.dev`, verifies its SHA256
checksum, and caches it in a Docker volume. On subsequent starts the cached
binaries are used directly.

Each container runs exactly one process. Use `RADICLE_VERSION` to run the
**node** (`radicle-node`), or `RADICLE_HTTPD_VERSION` to run the **HTTP daemon**
(`radicle-httpd`). Never both in the same container.

## Quick start (docker compose)

```yaml
services:
  radicle-node:
    image: pjzz/dynamic-radicle-docker:latest
    restart: unless-stopped
    environment:
      - RAD_HOME=/var/lib/radicle
      - RAD_PASSPHRASE=
      - RADICLE_VERSION=1.9.1
      - RAD_ALIAS=seed.example.com
      - RAD_EXTERNAL_ADDRESS=seed.example.com:8776
      - RAD_SEEDING_POLICY=allow
      - RAD_SEEDING_SCOPE=followed
    ports:
      - "8776:8776"
    volumes:
      - ./seed:/var/lib/radicle
      - radicle-bin:/opt/radicle
    healthcheck:
      test: ["CMD", "test", "-S", "/var/lib/radicle/node/control.sock"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 60s

  radicle-httpd:
    image: pjzz/dynamic-radicle-docker:latest
    restart: unless-stopped
    environment:
      - RAD_HOME=/var/lib/radicle
      - RADICLE_HTTPD_VERSION=0.25.0
    ports:
      - "127.0.0.1:8060:8080"
    volumes:
      - ./seed:/var/lib/radicle
      - radicle-bin:/opt/radicle
    depends_on:
      radicle-node:
        condition: service_healthy

volumes:
  radicle-bin:
```

Then:

```sh
docker compose up -d
```

## Quick start (docker run)

**Node:**

```sh
docker run -d \
  --name radicle-node \
  --restart unless-stopped \
  -v "$PWD/seed:/var/lib/radicle" \
  -v radicle-bin:/opt/radicle \
  -p 8776:8776 \
  -e RADICLE_VERSION=1.9.1 \
  -e RAD_ALIAS=seed.example.com \
  -e RAD_EXTERNAL_ADDRESS=seed.example.com:8776 \
  -e RAD_SEEDING_POLICY=allow \
  -e RAD_SEEDING_SCOPE=followed \
  pjzz/dynamic-radicle-docker:latest
```

**HTTP daemon:**

```sh
docker run -d \
  --name radicle-httpd \
  --restart unless-stopped \
  -v "$PWD/seed:/var/lib/radicle" \
  -v radicle-bin:/opt/radicle \
  -p 127.0.0.1:8060:8080 \
  -e RAD_HOME=/var/lib/radicle \
  -e RADICLE_HTTPD_VERSION=0.25.0 \
  pjzz/dynamic-radicle-docker:latest
```

## Environment variables

### Node container

| Variable | Required | Default | Description |
|---|---|---|---|
| `RADICLE_VERSION` | **Yes** | — | Radicle release version (e.g. `1.9.1`) or `latest` |
| `RAD_ALIAS` | No | `seed` | Node alias shown on the network |
| `RAD_EXTERNAL_ADDRESS` | No | — | External address (e.g. `seed.example.com:8776`) |
| `RAD_SEEDING_POLICY` | No | `allow` | Default seeding policy: `allow` or `block` |
| `RAD_SEEDING_SCOPE` | No | `all` | Seeding scope: `all` or `followed` |
| `RAD_HOME` | No | `/var/lib/radicle` | Radicle data directory |
| `RAD_PASSPHRASE` | No | *(empty)* | Passphrase for the node key (empty = no passphrase) |
| `RAD_NODE_LISTEN` | No | `0.0.0.0:8776` | Address for the node to listen on |

### HTTP daemon container

| Variable | Required | Default | Description |
|---|---|---|---|
| `RADICLE_HTTPD_VERSION` | **Yes** | — | radicle-httpd release version (e.g. `0.25.0`) or `latest` |
| `RAD_HOME` | No | `/var/lib/radicle` | Radicle data directory (must match node) |
| `RAD_HTTPD_LISTEN` | No | `0.0.0.0:8080` | Address for httpd to listen on |

## Upgrades and downgrades

Change the version env var and restart:

```sh
# Upgrade node
docker compose up -d radicle-node   # after editing docker-compose.yml

# Downgrade
# Just set the version back and restart
```

The binary cache volume (`radicle-bin`) retains old versions, so switching
back and forth is instant after the first download of each version.

**Important:** The `rad` CLI on your host machine must match the node version
exactly. Upgrade the host CLI separately:

```sh
curl -sSLf https://radicle.xyz/install | sh
```

## Configuration precedence

The node's `config.json` (in the data volume at `RAD_HOME/config.json`)
follows this precedence, from highest to lowest:

1. **Existing `config.json`** — If the file already exists in the data volume
   (whether user-created or from a previous first-run), it is always used
   as-is. Env vars are ignored for config purposes.

2. **Env vars (first run only)** — If no `config.json` exists, one is
   generated from `RAD_ALIAS`, `RAD_EXTERNAL_ADDRESS`,
   `RAD_SEEDING_POLICY`, and `RAD_SEEDING_SCOPE`.

3. **`RAD_NODE_LISTEN`** — This is passed as a `--listen` flag directly to
   `radicle-node` at every startup, overriding the `listen` field in
   `config.json`.

4. **`RADICLE_VERSION` / `RADICLE_HTTPD_VERSION`** — These control which
   binary is downloaded, independent of config.

**To customize config after first run:** Edit `config.json` directly in the
data volume. Env var changes to alias/policy/scope/external-address will have
no effect once the file exists.

## First-run behavior

On first start with an empty data volume, the node container will:

1. Download and cache the requested Radicle binaries
2. Generate a new Ed25519 key pair (`rad auth`)
3. Generate `config.json` from the environment variables

If you pre-create `config.json` in the data volume before first start, your
file is preserved (the entrypoint backs it up during `rad auth` and restores
it). This lets you configure advanced settings (limits, relay mode, etc.)
that aren't exposed via env vars.

## Reverse proxy

The HTTP daemon serves plain HTTP on port 8080. Put it behind a reverse proxy
(Apache, Nginx, Caddy) for TLS termination. The Radicle Explorer SPA can be
served as static files alongside the reverse-proxied `/api/` endpoints.

## Building from source

```sh
# Install task: https://taskfile.dev
task build       # builds image tagged as pjzz/dynamic-radicle-docker:dev
task release     # builds, tags with YYYY.MM.DD.n, and pushes to Docker Hub
```
