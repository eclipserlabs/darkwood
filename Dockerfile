# Phoenix 1.8 multi-stage release image.
ARG ELIXIR_VERSION=1.17
ARG OTP_VERSION=27
ARG DEBIAN_VERSION=trixie-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y && apt-get install -y build-essential git nodejs npm \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.setup
RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:${DEBIAN_VERSION} AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/darkwood ./
USER nobody

ENV PHX_SERVER=true
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD wget -qO- http://127.0.0.1:4000/health | grep -q '"status":"ok"' || exit 1

CMD ["bin/darkwood", "start"]
