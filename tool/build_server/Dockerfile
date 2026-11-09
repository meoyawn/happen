## Build environment only. The deployed server runs as a native AOT executable.
FROM dart:3.13.7-sdk@sha256:854f3c50b1cbd4a5a54c9fa67d4f5b6702ac49b4a26d21a80e7712a72528b215 AS sdk
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-download-retries \
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates clang libc6-dev pkg-config git \
    && rm -rf /var/lib/apt/lists/*
COPY --from=sdk /usr/lib/dart /opt/dart
ENV PATH="/opt/dart/bin:${PATH}"
WORKDIR /source
ENTRYPOINT ["dart"]
