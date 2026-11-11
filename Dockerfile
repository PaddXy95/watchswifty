# syntax=docker/dockerfile:1

# ---- Build ----
FROM swift:6.4-noble AS build
WORKDIR /build

# Resolve and compile the dependencies first, with stub sources standing in for the app: these layers stay
# cached (GitHub Actions cache) until Package.swift/Package.resolved change, so a normal push only compiles the app.
COPY ./Package.* ./
RUN swift package resolve
RUN mkdir -p Sources/App Sources/WatchSwiftyAPI Sources/WatchSwiftyClient Tests/AppTests/Fixtures \
        Tests/WatchSwiftyClientTests \
    && echo 'print("stub")' > Sources/App/main.swift \
    && echo '' > Sources/WatchSwiftyClient/Stub.swift \
    && echo '' > Tests/WatchSwiftyClientTests/Stub.swift \
    && echo '' > Sources/WatchSwiftyAPI/Stub.swift \
    && printf 'openapi: 3.1.0\ninfo: {title: stub, version: "0"}\npaths: {}\n' > Sources/WatchSwiftyAPI/openapi.yaml \
    && printf 'generate: [types, server]\naccessModifier: package\n' > Sources/WatchSwiftyAPI/openapi-generator-config.yaml \
    && echo '' > Tests/AppTests/Stub.swift \
    && swift build -c release --static-swift-stdlib --product App \
    && rm -rf Sources Tests

COPY . .
RUN swift build -c release --static-swift-stdlib --product App

WORKDIR /staging
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/App" ./ \
    && cp -RL /build/Public ./Public

# ---- Run ----
FROM ubuntu:noble

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor \
    && chmod 755 /app \
    && mkdir -p /data && chown vapor:vapor /data

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app
COPY --chmod=755 scripts/docker-entrypoint.sh /app/docker-entrypoint.sh

# Version info for the footer and /version (set by the GitHub Action).
ARG APP_VERSION=dev
ARG GIT_COMMIT=
ENV APP_VERSION=$APP_VERSION
ENV GIT_COMMIT=$GIT_COMMIT

ENV DATABASE_PATH=/data/watchswifty.sqlite
VOLUME /data
EXPOSE 8080

# Starts as root only to hand /data to the user `vapor` (bind mounts), then runs the app as `vapor`.
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["serve", "--env", "production"]
