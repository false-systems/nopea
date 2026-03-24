# Oracle test binary for Nopea
# Runs against a live Nopea instance via HTTP API and MCP protocol
#
# Build:  docker build -t nopea-oracle:latest eval/oracle/
# Run:    docker run --rm -e NOPEA_URL=http://nopea:4000 nopea-oracle:latest

FROM elixir:1.16-alpine AS builder

RUN apk add --no-cache build-base git

WORKDIR /build

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=test

COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

COPY config ./config
COPY lib ./lib
COPY test ./test
COPY .formatter.exs ./

RUN mix compile

# Runtime — same image, just run tests
# We keep it single-stage since oracle is test-only
CMD ["mix", "test", "--no-start", "--color"]
