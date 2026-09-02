ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20241223-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
RUN chmod +x rel/overlays/bin/migrate && mix compile && mix assets.deploy && mix release

FROM ${RUNNER_IMAGE} AS runner
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN chown nobody /app
ENV LANG=C.UTF-8 PHX_SERVER=true
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/strangertalks_new ./
USER nobody
EXPOSE 4000
CMD ["bin/strangertalks_new", "start"]
