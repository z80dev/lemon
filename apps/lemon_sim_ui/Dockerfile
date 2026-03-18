FROM hexpm/elixir:1.19.1-erlang-27.3.4-debian-bookworm-20250127 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
COPY apps apps

RUN mix deps.get
RUN mix release sim_broadcast_platform

FROM debian:bookworm-slim AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      ca-certificates \
      libncurses6 \
      libtinfo6 \
      sqlite3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV HOME=/app
ENV PHX_SERVER=true
ENV RELEASE_NAME=sim_broadcast_platform

COPY --from=build /app/_build/prod/rel/sim_broadcast_platform ./

EXPOSE 4090

CMD ["/app/bin/sim_broadcast_platform", "start"]
