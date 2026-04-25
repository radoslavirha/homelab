FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# influx CLI — InfluxData GitHub release
ARG INFLUX_VERSION=2.8.0
RUN curl -sLo /tmp/influx.tar.gz \
    "https://dl.influxdata.com/influxdb/releases/influxdb2-client-${INFLUX_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/influx.tar.gz -C /usr/local/bin/ --strip-components=0 ./influx \
    && rm /tmp/influx.tar.gz \
    && chmod +x /usr/local/bin/influx

# bao CLI — OpenBao GitHub release
ARG BAO_VERSION=2.5.3
RUN curl -sLo /tmp/bao.tar.gz \
    "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/bao_${BAO_VERSION}_Linux_x86_64.tar.gz" \
    && tar -xzf /tmp/bao.tar.gz -C /usr/local/bin/ bao \
    && rm /tmp/bao.tar.gz \
    && chmod +x /usr/local/bin/bao

# mongosh — MongoDB official deb repo
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
      | gpg --dearmor > /etc/apt/trusted.gpg.d/mongodb.gpg \
    && echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" \
      > /etc/apt/sources.list.d/mongodb-org.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends mongodb-mongosh \
    && rm -rf /var/lib/apt/lists/*
