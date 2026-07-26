# syntax=docker/dockerfile:1
# Builds and runs the JMAP -> APNs push relay. Build context is the repo root.

FROM swift:6.2 AS build
WORKDIR /build
# Resolve dependencies first so the layer caches across source edits.
COPY Package.swift Package.resolved ./
RUN swift package resolve
# SPM validates every declared target path (incl. the test target) when it
# loads the manifest, so both source trees must be present even for a
# product-only build.
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product PushRelay

FROM swift:6.2-slim
# ca-certificates so the relay can validate api.push.apple.com for real APNs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/.build/release/PushRelay /usr/local/bin/PushRelay
EXPOSE 8443
# Port, TLS, and APNs config all come from the environment (see README).
ENTRYPOINT ["PushRelay"]
