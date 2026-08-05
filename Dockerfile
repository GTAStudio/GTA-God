# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

FROM debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

ARG APP_VERSION=0.1.0
LABEL org.opencontainers.image.title="GTA-God" \
    org.opencontainers.image.version="${APP_VERSION}" \
    org.opencontainers.image.source="https://github.com/GTAStudio/GTA-God"

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libcap2-bin netcat-openbsd && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -g 65532 app && \
    useradd -u 65532 -g 65532 -M -s /usr/sbin/nologin -d /nonexistent app && \
    mkdir -p /config /data /etc/gta-god /opt/gta-god /var/log/app && \
    chown -R app:app /config /data /var/log/app

COPY payload/runtime.tar.gz payload/runtime.tar.gz.sha256 /tmp/
RUN cd /tmp && \
    sha256sum -c runtime.tar.gz.sha256 && \
    tar -xzf runtime.tar.gz -C /opt/gta-god --strip-components=1 && \
    chmod 0755 /opt/gta-god/edge /opt/gta-god/manager /opt/gta-god/runtime \
        /opt/gta-god/libcronet.so && \
    rm -f runtime.tar.gz runtime.tar.gz.sha256 && \
    setcap 'cap_net_bind_service=+ep' /opt/gta-god/edge && \
    /opt/gta-god/edge --version >/dev/null

ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data \
    APP_VERSION=${APP_VERSION} \
    TZ=Asia/Shanghai

VOLUME ["/config", "/data", "/var/log/app"]
WORKDIR /data
STOPSIGNAL SIGTERM
USER app

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --start-interval=5s --retries=3 \
    CMD ["/opt/gta-god/edge", "--healthcheck", "/etc/gta-god/config.json"]

ENTRYPOINT ["/opt/gta-god/edge"]
CMD ["/etc/gta-god/config.json"]