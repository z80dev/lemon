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

COPY --from=release /app/_build/prod/rel/lemon_runtime_full /opt/lemon
RUN chmod -R a+rX /opt/lemon && ln -s /opt/lemon/bin/lemon /usr/local/bin/lemon

ENV RELEASE_TMP=/tmp/lemon-release
