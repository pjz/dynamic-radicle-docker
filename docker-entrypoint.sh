#!/bin/sh
set -e

TARGET="x86_64-unknown-linux-musl"
BASE_URL="https://files.radicle.dev/releases"
CACHE_ROOT="/opt/radicle"

export RAD_HOME="${RAD_HOME:-/var/lib/radicle}"
export RAD_PASSPHRASE="${RAD_PASSPHRASE:-}"

# ---------------------------------------------------------------------------
# Validate: exactly one version env var must be set
# ---------------------------------------------------------------------------
if [ -n "${RADICLE_VERSION:-}" ] && [ -n "${RADICLE_HTTPD_VERSION:-}" ]; then
    echo "error: Both RADICLE_VERSION and RADICLE_HTTPD_VERSION are set."
    echo "       Set only one per container." >&2
    exit 1
fi

if [ -z "${RADICLE_VERSION:-}" ] && [ -z "${RADICLE_HTTPD_VERSION:-}" ]; then
    echo "error: Set either RADICLE_VERSION or RADICLE_HTTPD_VERSION." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# resolve_version  <raw> <json_url>
# Outputs the resolved version string to stdout.
# If raw is "latest", fetches the JSON metadata to get the actual version.
# ---------------------------------------------------------------------------
resolve_version() {
    raw="$1"
    json_url="$2"

    if [ "$raw" = "latest" ]; then
        resolved=$(curl -sSfL "$json_url" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "$resolved" ]; then
            echo "error: Failed to resolve latest version from $json_url" >&2
            exit 1
        fi
        echo "$resolved"
    else
        echo "$raw"
    fi
}

# ---------------------------------------------------------------------------
# fetch_and_cache  <version> <subdir> <archive_prefix> <url_base>
# Downloads, verifies SHA256, and extracts the tarball to the cache dir.
# ---------------------------------------------------------------------------
fetch_and_cache() {
    version="$1"
    cache_subdir="$2"
    archive_prefix="$3"
    url_base="$4"

    cache="${CACHE_ROOT}/${cache_subdir}"
    archive="${archive_prefix}-${version}-${TARGET}.tar.xz"
    url="${url_base}/${version}/${archive}"

    if [ -x "${cache}/bin/${BINARY_NAME}" ]; then
        echo "Using cached ${BINARY_NAME} ${version}"
        return 0
    fi

    echo "Downloading ${archive}..."
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    curl -sSfL -o "${tmp}/${archive}" "${url}"
    curl -sSfL -o "${tmp}/${archive}.sha256" "${url}.sha256"

    echo "Verifying SHA256..."
    (cd "$tmp" && sha256sum -c "${archive}.sha256")

    mkdir -p "$cache"
    tar -xJf "${tmp}/${archive}" --strip-components=1 -C "$cache"
    echo "Installed ${archive_prefix} ${version}"
}

# ---------------------------------------------------------------------------
# generate_config
# Writes RAD_HOME/config.json from env vars (unconditionally).
# ---------------------------------------------------------------------------
generate_config() {
    echo "Generating config.json..."
    mkdir -p "$RAD_HOME"

    alias_val="${RAD_ALIAS:-seed}"
    policy_val="${RAD_SEEDING_POLICY:-allow}"
    scope_val="${RAD_SEEDING_SCOPE:-all}"

    if [ -n "${RAD_EXTERNAL_ADDRESS:-}" ]; then
        cat > "${RAD_HOME}/config.json" <<EOF
{
  "node": {
    "alias": "${alias_val}",
    "listen": ["0.0.0.0:8776"],
    "externalAddresses": ["${RAD_EXTERNAL_ADDRESS}"],
    "seedingPolicy": {
      "default": "${policy_val}",
      "scope": "${scope_val}"
    }
  }
}
EOF
    else
        cat > "${RAD_HOME}/config.json" <<EOF
{
  "node": {
    "alias": "${alias_val}",
    "listen": ["0.0.0.0:8776"],
    "seedingPolicy": {
      "default": "${policy_val}",
      "scope": "${scope_val}"
    }
  }
}
EOF
    fi
}

# ===========================================================================
# Node role
# ===========================================================================
if [ -n "${RADICLE_VERSION:-}" ]; then
    BINARY_NAME="radicle-node"
    VERSION=$(resolve_version "${RADICLE_VERSION}" "${BASE_URL}/latest/radicle.json")
    echo "Radicle node version: ${VERSION}"

    fetch_and_cache "$VERSION" "$VERSION" "radicle" "${BASE_URL}"

    ln -sf "${CACHE_ROOT}/${VERSION}/bin/"* /usr/local/bin/
    export PATH="${CACHE_ROOT}/${VERSION}/bin:${PATH}"

    # First-run: generate identity and config
    if [ ! -f "${RAD_HOME}/keys/radicle.pub" ]; then
        echo "First run: creating Radicle identity..."

        # rad auth overwrites config.json, so back up any user-provided config
        if [ -f "${RAD_HOME}/config.json" ]; then
            cp "${RAD_HOME}/config.json" "${RAD_HOME}/config.json.bak"
        fi

        rad auth --alias "${RAD_ALIAS:-seed}"

        # Restore user config if we backed it up, otherwise generate from env vars
        if [ -f "${RAD_HOME}/config.json.bak" ]; then
            mv "${RAD_HOME}/config.json.bak" "${RAD_HOME}/config.json"
            echo "Preserved existing config.json"
        else
            generate_config
        fi
    fi

    echo "Starting radicle-node..."
    exec radicle-node --listen "${RAD_NODE_LISTEN:-0.0.0.0:8776}"

# ===========================================================================
# HTTPD role
# ===========================================================================
elif [ -n "${RADICLE_HTTPD_VERSION:-}" ]; then
    BINARY_NAME="radicle-httpd"
    VERSION=$(resolve_version "${RADICLE_HTTPD_VERSION}" "${BASE_URL}/radicle-httpd/latest/radicle-httpd.json")
    echo "Radicle httpd version: ${VERSION}"

    fetch_and_cache "$VERSION" "httpd-${VERSION}" "radicle-httpd" "${BASE_URL}/radicle-httpd"

    echo "Starting radicle-httpd..."
    exec "${CACHE_ROOT}/httpd-${VERSION}/bin/radicle-httpd" \
        --listen "${RAD_HTTPD_LISTEN:-0.0.0.0:8080}"
fi
