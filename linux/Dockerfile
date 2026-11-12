# The Rust core, CLI and plugin template on Linux. Network is needed only while building:
#   docker build -f linux/Dockerfile -t haunt-linux .
#   docker run --rm --network none haunt-linux
FROM rust:1.98.0-slim-bookworm

# git: `haunt plugin new` runs `git init`.
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
RUN git config --global user.email ci@localhost && git config --global user.name ci

WORKDIR /haunt
COPY . .
# Installs the pinned toolchain and targets, then every crate the workspace and the plugin template use.
RUN cargo fetch --locked && cargo fetch --locked --manifest-path cli/template/Cargo.toml
RUN cargo test --workspace --locked --offline --no-run && cargo build -p haunt-cli --locked --offline

ENV CARGO_NET_OFFLINE=true
CMD ["linux/check.sh"]
