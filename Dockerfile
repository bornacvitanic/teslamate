# syntax=docker/dockerfile:1.7
FROM elixir:1.19.5-otp-26 AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y ca-certificates curl gnupg zstd brotli \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
     | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && NODE_MAJOR=22 \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
     | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install nodejs -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.rebar --force && \
    mix local.hex --force

ENV MIX_ENV=prod \
    SKIP_LOCALE_DOWNLOAD=true
WORKDIR /opt/app

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config/$MIX_ENV.exs config/$MIX_ENV.exs
COPY config/config.exs config/config.exs
RUN mix deps.compile

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix ./assets --progress=false --no-audit --loglevel=error

COPY assets assets
COPY priv/static priv/static
RUN mix assets.deploy

COPY lib lib
COPY priv/repo/migrations priv/repo/migrations
COPY priv/gettext priv/gettext
COPY grafana/dashboards grafana/dashboards
COPY VERSION VERSION

# Pre-fetch CLDR locale JSON to priv/cldr/locales/ so ex_cldr uses the
# cache instead of downloading at compile time. Works around GitHub's
# aggressive raw.githubusercontent.com rate limits on Actions runners.
# LOCALES env is read by lib/teslamate_web/cldr.ex as data_dir.
ENV LOCALES=/opt/app/priv/cldr
RUN mkdir -p "$LOCALES/locales" && cd "$LOCALES/locales" \
    && for gl in $(ls /opt/app/priv/gettext); do \
         [ -d "/opt/app/priv/gettext/$gl" ] || continue; \
         cl="${gl//_/-}"; \
         for attempt in 1 2 3 4 5 6; do \
           if curl -fsSLo "$cl.json" "https://raw.githubusercontent.com/elixir-cldr/cldr/v2.46.0/priv/cldr/locales/$cl.json"; then \
             echo "fetched $cl"; break; \
           fi; \
           echo "retry $attempt for $cl"; sleep $((attempt * 10)); \
         done; \
       done \
    && curl -fsSLo en.json "https://raw.githubusercontent.com/elixir-cldr/cldr/v2.46.0/priv/cldr/locales/en.json" \
    && ls -la "$LOCALES/locales"

# BuildKit cache mount on _build/ lets Elixir skip unchanged modules between
# builds — huge speedup for template/CSS-only iterations.
RUN --mount=type=cache,target=/opt/app/_build,id=teslamate-build,sharing=locked \
    mix compile

COPY config/runtime.exs config/runtime.exs
RUN --mount=type=cache,target=/opt/app/_build,id=teslamate-build,sharing=locked \
    SKIP_LOCALE_DOWNLOAD=true mix release --path /opt/built

########################################################################

FROM debian:trixie-slim AS app

ENV LANG=C.UTF-8 \
    SRTM_CACHE=/opt/app/.srtm_cache \
    HOME=/opt/app

WORKDIR $HOME

RUN apt-get update && apt-get install -y --no-install-recommends \
        libodbc2 \
        libsctp1 \
        libssl3t64 \
        libstdc++6 \
        netcat-openbsd \
        tini \
        tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 --system nonroot \
    && useradd  --uid 10000 --system --gid nonroot --home-dir /home/nonroot --shell /sbin/nologin nonroot \
    && chown -R nonroot:nonroot .

USER nonroot:nonroot
COPY --chown=nonroot:nonroot --chmod=555 entrypoint.sh /
COPY --from=builder --chown=nonroot:nonroot --chmod=555 /opt/built .
RUN mkdir $SRTM_CACHE

EXPOSE 4000

ENTRYPOINT ["tini", "--", "/bin/dash", "/entrypoint.sh"]
CMD ["bin/teslamate", "start"]
