# Shared toolchain image for isolated coding-agent trials. Both agent images
# build FROM this, so every task sees identical interpreters and compilers.
#
#   docker build -f apps/lemon_evals/priv/coding_arena/base.Dockerfile \
#     -t lemon-arena-base apps/lemon_evals/priv/coding_arena
FROM node:22-bookworm

ARG TARGETARCH
ARG GO_VERSION=1.23.4

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 python3-venv sqlite3 jq ripgrep fd-find less procps file \
      build-essential git curl ca-certificates && \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd && \
    ln -sf /usr/bin/python3 /usr/local/bin/python && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | tar -C /usr/local -xz

ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path && \
    chmod -R a+rwX /usr/local/rustup /usr/local/cargo

ENV PATH=/usr/local/go/bin:/usr/local/cargo/bin:$PATH \
    GOTOOLCHAIN=local GOPROXY=off GOCACHE=/tmp/go-cache \
    CARGO_NET_OFFLINE=true \
    LANG=C.UTF-8 LC_ALL=C.UTF-8

# Login shells (`bash -l`) rebuild PATH from /etc/profile; keep toolchains visible there too.
RUN env | grep -E '^(PATH|RUSTUP_HOME|CARGO_HOME|GOTOOLCHAIN|GOPROXY|GOCACHE|CARGO_NET_OFFLINE)=' | \
      sed 's/^/export /' > /etc/profile.d/arena-toolchains.sh

# Trials run as an unprivileged user whose HOME holds only that agent's state.
RUN useradd --create-home --uid 1001 --shell /bin/bash agent && \
    mkdir -p /work /verify && chown agent:agent /work /verify

WORKDIR /work
