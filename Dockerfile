FROM golang:1.25-bookworm AS seaweedfs-builder

WORKDIR /src/seaweedfs
COPY go.mod /src/seaweedfs/go.mod
COPY go.sum /src/seaweedfs/go.sum
COPY weed /src/seaweedfs/weed
COPY telemetry/proto /src/seaweedfs/telemetry/proto
RUN CGO_ENABLED=0 go build -o /out/weed ./weed

FROM debian:bookworm-slim AS debian-keyring

FROM seleniarm/standalone-chromium:latest

USER root

COPY --from=seaweedfs-builder /out/weed /usr/local/bin/weed
COPY --from=debian-keyring /usr/share/keyrings/debian-archive-keyring.gpg /usr/share/keyrings/debian-archive-keyring.gpg
COPY entrypoint-with-weed.sh /opt/bin/entrypoint-with-weed.sh

RUN rm -f /etc/apt/sources.list.d/* \
    && printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm main' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm-updates main' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian-security bookworm-security main' \
       > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends fuse3 \
    && printf 'user_allow_other\n' >> /etc/fuse.conf \
    && if [ -x /bin/fusermount3 ] && [ ! -e /bin/fusermount ]; then ln -s /bin/fusermount3 /bin/fusermount; fi \
    && rm -rf /var/lib/apt/lists/* \
    && chmod +x /usr/local/bin/weed /opt/bin/entrypoint-with-weed.sh \
    && mkdir -p /mnt \
    && chown -R seluser:seluser /mnt

USER seluser

CMD ["/opt/bin/entrypoint-with-weed.sh"]
