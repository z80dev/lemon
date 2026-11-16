# Lemon trial image: the arena toolchains plus a lemon_runtime_full release.
# The release comes from the build stage of docker/Dockerfile.runtime:
#
#   docker build -f docker/Dockerfile.runtime --target build -t lemon-arena-build .
#   docker build -f apps/lemon_evals/priv/coding_arena/lemon.Dockerfile \
#     -t lemon-arena-lemon apps/lemon_evals/priv/coding_arena
FROM lemon-arena-build AS release

FROM lemon-arena-base

RUN apt-get update && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libtinfo6 inotify-tools && \
    rm -rf /var/lib/apt/lists/*

# Code-mode cells require Deno 2; never fall back to an ambient-authority kernel.
ARG DENO_VERSION=2.5.6
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      arm64) target=aarch64; checksum=f5e60ae3dfceb61e5e5a41f22129e40a8bc17f6393b59e75d7ca19ceef32d824 ;; \
      amd64) target=x86_64; checksum=fd4f6abc1b6a134fa9a4dba56519f1631f44c88e04e4e3e9a8ff5975dfa66e1a ;; \
      *) echo "Unsupported Deno architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${target}-unknown-linux-gnu.zip" -o /tmp/deno.zip; \
    printf '%s  /tmp/deno.zip\n' "$checksum" | sha256sum -c -; \
    python3 -m zipfile -e /tmp/deno.zip /usr/local/bin; \
    chmod 0755 /usr/local/bin/deno; \
    rm /tmp/deno.zip

COPY --from=release /app/_build/prod/rel/lemon_runtime_full /opt/lemon
RUN chmod -R a+rX /opt/lemon && ln -s /opt/lemon/bin/lemon /usr/local/bin/lemon

ENV RELEASE_TMP=/tmp/lemon-release
