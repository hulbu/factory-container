# syntax=docker/dockerfile:1.7
#
# HulbuFactory as a container, for amd64 and arm64.
#
# The image is only what HulbuFactory needs around it: Debian 12 (slim), git, bubblewrap, ca-certificates, GitHub's
# gh, and Node (only to run the coding agents). The HulbuFactory program itself is NOT in the image: the entrypoint
# downloads it from releases.hulbu.com at start, checks its signature and checksums, and installs it into the volume.
# The coding agents are installed into the volume at run time too. No Rust, no compiler, nothing built here.

ARG TARGETARCH
ARG NODE_VERSION=24.22.3

# Node, the official tarball. These two stages only fetch one file each and check its SHA-256; nothing else of them
# reaches the image. The values are from https://nodejs.org/dist/v24.22.3/SHASUMS256.txt, whose signature was
# checked against Node's release keys (github.com/nodejs/release-keys) when they were pinned.
FROM scratch AS node-amd64
ARG NODE_VERSION
ADD --checksum=sha256:061ec3e3062115705b56b51fa9cc330ab50d34b6969387d4e4b1a50c6809acc2 \
    https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz /node.tar.gz

FROM scratch AS node-arm64
ARG NODE_VERSION
ADD --checksum=sha256:261af2af250dfd7e9f25cf151d1b2713a0adf8f10a9ad116c4947f68627affe8 \
    https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.gz /node.tar.gz

FROM node-${TARGETARCH} AS node

# debian:bookworm-slim, pinned by the digest of its multi-architecture index (read 2026-11-18).
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

ARG TARGETARCH
ARG NODE_VERSION
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Layer 1: the system programs, from Debian. Versions are not pinned: Debian 12 keeps only the newest security
# release of each package, so the image is rebuilt (weekly and on a change) to take them.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# Layer 2: gh, from GitHub's own Debian repository. Its keyring is committed in keys/ (fingerprint
# 7F38 BBB5 9D06 4DBC B3D8 4D72 5612 B364 6231 3325, read 2026-11-18).
COPY --chmod=0644 keys/github-cli-archive-keyring.gpg /usr/share/keyrings/github-cli-archive-keyring.gpg
# hadolint ignore=DL3008
RUN echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/github-cli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        >/etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Layer 3: Node into /usr/local, without its C headers and documentation (it keeps its LICENSE).
RUN --mount=type=bind,from=node,source=/node.tar.gz,target=/tmp/node.tar.gz \
    case "$TARGETARCH" in amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; *) exit 1 ;; esac \
    && top="node-v${NODE_VERSION}-linux-${node_arch}" \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 --no-same-owner \
        --exclude="$top/include" --exclude="$top/share" --exclude="$top/CHANGELOG.md" --exclude="$top/README.md" \
    && mkdir -p /usr/local/share/doc/node && mv /usr/local/LICENSE /usr/local/share/doc/node/LICENSE \
    && node --version && npm --version

# The person the service runs as (no sudo, no password), and its home: the one volume.
RUN groupadd --gid 10001 hulbu \
    && useradd --uid 10001 --gid 10001 --create-home --home-dir /home/hulbu --shell /bin/bash hulbu

# Layer 4: the entrypoint, the release check, the pinned keys. Root-owned, read only for the service.
COPY --chmod=0644 keys/hulbu-release-current.pub keys/hulbu-release-next.pub /usr/local/share/hulbu-factory/keys/
COPY --chmod=0644 entrypoint/agents.json entrypoint/npmrc /usr/local/share/hulbu-factory/
COPY --chmod=0644 entrypoint/verify-release.mjs /usr/local/lib/hulbu-factory/verify-release.mjs
COPY --chmod=0755 entrypoint/start.sh /usr/local/lib/hulbu-factory/start.sh
COPY --chmod=0755 bin/hulbu /usr/local/bin/hulbu

# Fixed values of the image, none of them a secret or a choice: secrets in files (and so every agent sandboxed, or not
# started); the agents last on PATH, so nothing in the volume can stand in for a system program.
ENV HULBU_SECRET_STORE=file \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/hulbu/.local/share/hulbu-factory/agents/bin

LABEL org.opencontainers.image.title="HulbuFactory container" \
      org.opencontainers.image.description="A HulbuFactory device: takes jobs from hulbu.com and runs coding agents." \
      org.opencontainers.image.source="https://github.com/hulbu/factory-container"

USER 10001:10001
WORKDIR /home/hulbu
ENTRYPOINT ["/usr/local/lib/hulbu-factory/start.sh"]
