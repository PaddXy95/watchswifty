# syntax=docker/dockerfile:1

# ---- Build ----
FROM swift:6.4-noble AS build
WORKDIR /build

# Resolve dependencies first so this layer is cached between source changes.
COPY ./Package.* ./
RUN swift package resolve

COPY . .
RUN swift build -c release --static-swift-stdlib --product App

WORKDIR /staging
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/App" ./ \
    && cp -R /build/Public ./Public

# ---- Run ----
FROM ubuntu:noble

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor \
    && mkdir -p /data && chown vapor:vapor /data

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app

ENV DATABASE_PATH=/data/watchswifty.sqlite
USER vapor:vapor
VOLUME /data
EXPOSE 8080

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production"]
