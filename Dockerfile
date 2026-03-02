# Multi-stage Dockerfile for games_platform release
# Targets games.zeebot.xyz

# Stage 1: Build
FROM hexpm/elixir:1.19.0-erlang-27.0-debian-bookworm-20240612-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set up hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod
ENV LANG=C.UTF-8

# Create build directory
WORKDIR /app

# Copy mix files first for dependency caching
COPY mix.exs mix.lock ./
COPY apps/lemon_core/mix.exs apps/lemon_core/
COPY apps/lemon_games/mix.exs apps/lemon_games/
COPY apps/lemon_web/mix.exs apps/lemon_web/
COPY apps/lemon_gateway/mix.exs apps/lemon_gateway/
COPY apps/lemon_router/mix.exs apps/lemon_router/
COPY apps/lemon_control_plane/mix.exs apps/lemon_control_plane/
COPY apps/lemon_channels/mix.exs apps/lemon_channels/
COPY apps/lemon_services/mix.exs apps/lemon_services/
COPY apps/lemon_skills/mix.exs apps/lemon_skills/
COPY apps/ai/mix.exs apps/ai/
COPY apps/coding_agent/mix.exs apps/coding_agent/
COPY apps/coding_agent_ui/mix.exs apps/coding_agent_ui/
COPY apps/market_intel/mix.exs apps/market_intel/
COPY apps/lemon_automation/mix.exs apps/lemon_automation/
COPY apps/lemon_mcp/mix.exs apps/lemon_mcp/

# Install dependencies
RUN mix deps.get --only prod

# Copy config
COPY config config

# Copy application code
COPY apps apps

# Compile and build release
RUN mix compile
RUN mix release games_platform

# Stage 2: Runtime
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    openssl \
    libstdc++6 \
    locales \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set locale
ENV LANG=C.UTF-8
ENV MIX_ENV=prod

# Create app directory
WORKDIR /app

# Create data directory for SQLite
RUN mkdir -p /app/data

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/games_platform .

# Set up environment
ENV HOME=/app
ENV DATABASE_PATH=/app/data/games.db

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8080/healthz || exit 1

# Start the release
CMD ["bin/games_platform", "start"]
