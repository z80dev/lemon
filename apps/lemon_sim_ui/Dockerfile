ARG LEMON_GIT_SHA=unknown

FROM hexpm/elixir:1.19.5-erlang-28.5-debian-bookworm-20260505 AS build

ARG LEMON_GIT_SHA

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git nodejs npm && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod
ENV LEMON_GIT_SHA=$LEMON_GIT_SHA

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock hex_package.exs ./
COPY config config
COPY apps/lemon_ai apps/lemon_ai
COPY apps/lemon_agent apps/lemon_agent
COPY apps/lemon_core apps/lemon_core
COPY apps/lemon_sim apps/lemon_sim
COPY apps/lemon_sim_ui apps/lemon_sim_ui

RUN mix deps.get --only prod
RUN mix sim_ui.assets.deploy
RUN mix compile
RUN mix release sim_broadcast_platform --overwrite

FROM debian:bookworm-slim AS runtime

ARG LEMON_GIT_SHA

LABEL org.opencontainers.image.revision=$LEMON_GIT_SHA

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      ca-certificates \
      curl \
      gosu \
      inotify-tools \
      libncurses6 \
      libtinfo6 \
      sqlite3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV HOME=/home/lemon
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV ERL_CRASH_DUMP=/tmp/erl_crash.dump
ENV RELEASE_TMP=/tmp/lemon-release
ENV PHX_SERVER=true
ENV RELEASE_NAME=sim_broadcast_platform
ENV LEMON_GIT_SHA=$LEMON_GIT_SHA
ENV LEMON_STORE_PATH=/app/data/store
ENV LEMON_ARENA_LEAGUE_ROOT=/app/data/leagues

RUN groupadd --system --gid 10001 lemon && \
    useradd --uid 10001 --gid lemon --create-home --home-dir /home/lemon --shell /usr/sbin/nologin lemon && \
    mkdir -p /app/data/store /app/data/leagues && \
    chown -R lemon:lemon /app/data/store /app/data/leagues

COPY --from=build --chown=root:lemon /app/_build/prod/rel/sim_broadcast_platform ./
COPY --chown=root:root apps/lemon_sim_ui/docker-entrypoint.sh /usr/local/bin/lemon-sim-entrypoint

RUN chmod -R g+rX /app && chmod 0755 /usr/local/bin/lemon-sim-entrypoint

EXPOSE 4090

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl --fail --silent --show-error "http://127.0.0.1:${LEMON_SIM_UI_PORT:-4090}/readyz" >/dev/null || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/lemon-sim-entrypoint"]
CMD ["/app/bin/sim_broadcast_platform", "start"]
