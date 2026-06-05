# ---- Stage 1: Build ----
FROM hexpm/elixir:1.19.5-erlang-28.4-debian-bookworm-20260406-slim AS build

RUN apt-get update && apt-get install -y build-essential git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv
COPY rel rel
COPY assets assets

RUN mix compile && mix assets.deploy && mix release

# ---- Stage 2: Runtime ----
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=build /app/_build/prod/rel/tracy ./

ENV PHX_SERVER=true

EXPOSE 4000

CMD ["sh", "-c", "bin/migrate && bin/server"]
