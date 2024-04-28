################### Asset Builder

FROM node:22 AS build-assets
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]
ENV NO_UPDATE_NOTIFIER=1

WORKDIR /build/

COPY package.json package-lock.json ./
RUN \
    --mount=type=cache,target=/root/.npm,sharing=private \
<<EOT
    npm install --verbose
    npm audit fix
EOT

# not supported yet
#COPY --parents build-assets.mjs root/static ./

COPY build-assets.mjs ./
COPY root/static root/static
RUN <<EOT
    npm run build:min
EOT

################### Web Server
# hadolint ignore=DL3007
FROM metacpan/metacpan-base:latest AS server
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

RUN \
    --mount=type=cache,target=/var/cache/apt,sharing=private \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=private \
<<EOT
    apt-get update
    apt-get satisfy -y -f --no-install-recommends 'libcmark-dev (>= 0.30.2)'
EOT

WORKDIR /app/

COPY cpanfile cpanfile.snapshot ./
RUN \
    --mount=type=cache,target=/root/.perl-cpm,sharing=private \
<<EOT
    cpm install --show-build-log-on-failure --resolver=snapshot
EOT

RUN mkdir var && chown metacpan:users var

ENV PERL5LIB="/app/local/lib/perl5"
ENV PATH="/app/local/bin:${PATH}"

COPY *.md app.psgi *.conf ./
COPY bin bin
COPY lib lib
COPY root root
COPY --from=build-assets /build/root/assets root/assets

CMD [ \
    "/uwsgi.sh", \
    "--http-socket", ":80" \
]

EXPOSE 80

################### Development Server
FROM server AS develop

ENV COLUMNS="${COLUMNS:-120}"
ENV PLACK_ENV=development

USER root

RUN \
    --mount=type=cache,target=/root/.perl-cpm \
<<EOT
    cpm install --show-build-log-on-failure --resolver=snapshot --with-develop
    chown -R metacpan:users ./
EOT

USER metacpan

################### Test Runner
FROM develop AS test

ENV NO_UPDATE_NOTIFIER=1
ENV PLACK_ENV=

USER root

RUN \
    --mount=type=cache,target=/var/cache/apt,sharing=private \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=private \
    --mount=type=cache,target=/root/.npm,sharing=private \
<<EOT
    curl -fsSL https://deb.nodesource.com/setup_21.x | bash -
    apt-get update
    apt-get satisfy -y -f --no-install-recommends 'nodejs (>= 21.6.1)'
    npm install -g npm@^10.4.0
EOT

COPY package.json package-lock.json ./
RUN \
    --mount=type=cache,target=/root/.npm,sharing=private \
<<EOT
    npm install --verbose --include=dev
    npm audit fix
EOT

RUN \
    --mount=type=cache,target=/root/.perl-cpm \
<<EOT
    cpm install --show-build-log-on-failure --resolver=snapshot --with-test
EOT

COPY .perlcriticrc .perltidyrc perlimports.toml ./
COPY t t

USER metacpan
CMD [ "prove", "-l", "-r", "-j", "2", "t" ]

################### Production Server
FROM server AS production

USER metacpan
