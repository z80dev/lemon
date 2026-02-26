# Dockerfile for games.zeebot.xyz
# Builds a standalone games platform deployment

FROM hexpm/elixir:1.19.0-erlang-27.2-debian-bookworm-20250120 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set up build directory
WORKDIR /build

# Copy the umbrella project
COPY . /build/

# Install mix dependencies and compile
ENV MIX_ENV=prod
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix compile

# Build release
RUN mix release games_platform

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libstdc++6 \
    libncurses6 \
    openssl \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Create data directory for SQLite store
RUN mkdir -p /data

# Copy release from builder
COPY --from=builder /build/_build/prod/rel/games_platform ./

# Set environment
ENV MIX_ENV=prod
ENV LEMON_STORE_PATH=/data/store
ENV PORT=8080

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/healthz || exit 1

# Start the application
CMD ["./bin/games_platform", "start"]
