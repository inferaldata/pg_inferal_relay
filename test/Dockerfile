ARG PG_VERSION=18
FROM debian:bookworm-slim

ARG PG_VERSION
ARG PGTAP_VERSION=1.3.4
ARG PGSQL_HTTP_VERSION=1.7.0
ARG PG_NET_VERSION=0.20.2
ARG PG_TLE_VERSION=1.5.2

ENV PG_VERSION=${PG_VERSION}

# PGDG repo + PG server + build deps
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg \
        make gcc git patch flex libkrb5-dev \
        libcurl4-openssl-dev \
        libtap-parser-sourcehandler-pgtap-perl \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -so /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
         https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
         https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-${PG_VERSION} \
        postgresql-server-dev-${PG_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# Build pgTAP from source
RUN git clone --branch v${PGTAP_VERSION} --depth 1 \
        https://github.com/theory/pgtap.git /tmp/pgtap \
    && cd /tmp/pgtap && make && make install \
    && rm -rf /tmp/pgtap

# Build pgsql-http from source
RUN git clone --branch v${PGSQL_HTTP_VERSION} --depth 1 \
        https://github.com/pramsey/pgsql-http.git /tmp/pgsql-http \
    && cd /tmp/pgsql-http && make && make install \
    && rm -rf /tmp/pgsql-http

# Build pg_net from source
RUN git clone --branch v${PG_NET_VERSION} --depth 1 \
        https://github.com/supabase/pg_net.git /tmp/pg_net \
    && cd /tmp/pg_net && make && make install \
    && rm -rf /tmp/pg_net

# Build pg_tle from source
RUN git clone --branch v${PG_TLE_VERSION} --depth 1 \
        https://github.com/aws/pg_tle.git /tmp/pg_tle \
    && cd /tmp/pg_tle && make && make install \
    && rm -rf /tmp/pg_tle

# Build pg_curl from source (HEAD, no tagged releases)
RUN git clone --depth 1 \
        https://github.com/RekGRpth/pg_curl.git /tmp/pg_curl \
    && cd /tmp/pg_curl && make && make install \
    && rm -rf /tmp/pg_curl

# Strip build deps (keeps image smaller)
RUN apt-get purge -y --auto-remove gcc git make patch flex \
        postgresql-server-dev-${PG_VERSION} libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*
# Reinstall libcurl runtime (purged with -dev)
RUN apt-get update \
    && apt-get install -y --no-install-recommends libcurl4 less \
    && rm -rf /var/lib/apt/lists/*

ENV PAGER=less
