# The starter example as a container. Built from the repository root, because
# Examples/ depends on the Garuda checkout beside it:
#
#   docker build -f Examples/deploy/Dockerfile -t starter .
#   docker run --rm -p 8080:8080 \
#       -e APP_ENV=production \
#       -e DATABASE_URL='postgres://starter:secret@host.docker.internal:5432/starter?sslmode=require' \
#       -e JWT_PRIVATE_KEY="$(cat jwt.pem)" \
#       starter
#
# The schema: `docker run ... starter migrate` before rolling out, or let each
# shard migrate as it starts. Both are safe; Examples/STARTER.md says why.

FROM swift:6.3-noble AS build

# Garuda links the system's libssl, libcrypto and libz (INSTALLATION.md).
RUN apt-get update && apt-get install -y --no-install-recommends libssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
# Examples/ is its own package; --package-path builds it in place.
RUN swift build -c release --package-path Examples --product starter \
    && cp "$(swift build -c release --package-path Examples --show-bin-path)/starter" /usr/local/bin/starter

FROM ubuntu:noble

# What the binary needs beyond the Swift runtime: OpenSSL's libraries, zlib,
# the C++ runtime, time zones and CA certificates, and curl for the health
# check.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libssl3 zlib1g libstdc++6 curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# The Swift runtime libraries, from the build image.
COPY --from=build /usr/lib/swift/linux/*.so /usr/lib/swift/linux/
COPY --from=build /usr/local/bin/starter /usr/local/bin/starter
ENV LD_LIBRARY_PATH=/usr/lib/swift/linux

# Never root: nothing here needs a port below 1024.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin starter
USER 10001:10001

EXPOSE 8080
# Liveness only: --health-check-path answers before routing and touches no
# database, so a database outage does not restart the container.
HEALTHCHECK --interval=10s --timeout=2s --start-period=20s \
    CMD curl -fsS http://localhost:8080/health || exit 1

ENTRYPOINT ["starter"]
# --shards auto lets Vega choose the shard processes from the machine's CPUs,
# each with threads of its own. Under a CPU limit, give --shards and --threads
# that fit it. On SIGTERM (docker stop) the health check fails for
# --drain-delay milliseconds before the shards drain.
CMD ["serve", "--", "--host", "0.0.0.0", "--port", "8080", "--shards", "auto", \
     "--access-log", "--request-id", "--health-check-path", "/health", "--drain-delay", "5000"]
