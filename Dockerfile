# Stage 1: Build Elixir release
FROM elixir:1.16-alpine AS builder

RUN apk add --no-cache build-base git

WORKDIR /build

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Copy false_protocol dependency (local path dep)
COPY false-protocol-elixir ./false-protocol-elixir

# Copy mix files first for dependency caching
COPY mix.exs mix.lock ./

# Rewrite local path dep for Docker context
RUN sed -i 's|path: "../false-protocol/elixir"|path: "./false-protocol-elixir"|' mix.exs

RUN mix deps.get --only prod
RUN mix deps.compile

# Copy source code
COPY lib ./lib
COPY config ./config

# Compile and build release
RUN mix compile
RUN mix release

# Stage 2: Runtime image
FROM alpine:3.19

RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    ca-certificates

WORKDIR /app

# Copy Elixir release
COPY --from=builder /build/_build/prod/rel/nopea ./

# Create working directory for graph persistence
RUN mkdir -p /app/.nopea

ENV HOME=/app
ENV RELEASE_COOKIE=nopea_cookie

EXPOSE 4000

CMD ["bin/nopea", "start"]
