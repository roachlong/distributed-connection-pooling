# using Debian 11 base image
FROM docker.io/debian:bullseye-slim

LABEL maintainer="Cockroach Labs PS <lee.long@cockroachlabs.com>"

# optional environment variable that's used in later lines and set as envvar when container is running
ARG PGBOUNCER_VERSION=1.17.0

RUN set -x \
# increase file limit descriptors in os to handle the number of client connections that will be served through PGBouncer
    && sed -i '/^# End of file/d' /etc/security/limits.conf \
    && sed -i '/^\*               hard    nofile          /{h;s/nofile          .*/nofile          50000/};${x;/^$/{s//\*               hard    nofile          50000/;H};x}' /etc/security/limits.conf \
    && sed -i '/^\*               soft    nofile          /{h;s/nofile          .*/nofile          50000/};${x;/^$/{s//\*               soft    nofile          50000/;H};x}' /etc/security/limits.conf \
    && sed -i '/^\*               hard    nproc           /{h;s/nproc           .*/nproc           10000/};${x;/^$/{s//\*               hard    nproc           10000/;H};x}' /etc/security/limits.conf \
    && sed -i '/^\*               soft    nproc           /{h;s/nproc           .*/nproc           10000/};${x;/^$/{s//\*               soft    nproc           10000/;H};x}' /etc/security/limits.conf \
    && echo "# End of file" | tee -a /etc/security/limits.conf > /dev/null \
    && apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends --no-install-suggests procps \
    #&& sysctl -w net.ipv4.ip_local_port_range="10000 65000" \
    #&& sed -i '/^vm.swappiness =/{h;s/=.*/= 0/};${x;/^$/{s//vm.swappiness = 0/;H};x}' /etc/sysctl.conf \
    #&& sysctl --system \
# install psotgres client, pgbouncer and dependencies
    && apt-get install -y postgresql-client pgbouncer libevent-dev pkg-config libssl-dev wget build-essential \
# updating pgbouncer to required version from Debian 11 default, which is currently 1.12'
    && wget https://www.pgbouncer.org/downloads/files/${PGBOUNCER_VERSION}/pgbouncer-${PGBOUNCER_VERSION}.tar.gz \
    && tar -xvf pgbouncer-${PGBOUNCER_VERSION}.tar.gz \
    && rm pgbouncer-${PGBOUNCER_VERSION}.tar.gz \
    && cd pgbouncer-${PGBOUNCER_VERSION}/ && ./configure --prefix=/usr/local && make && make install \
    && apt-get remove --purge --auto-remove -y && rm -rf /var/lib/apt/lists/* \
# foward pgbouncer logs to docker log collector
    #&& ln -sf /dev/stdout /var/lib/postgresql/pgbouncer.log \
# create directories to store configuration files
    && mkdir -p /var/lib/postgresql/conf

COPY ./*.sh /var/lib/postgresql/conf/
COPY ./*.template /var/lib/postgresql/conf/
WORKDIR /var/lib/postgresql/conf
RUN chown -R postgres:postgres ../
EXPOSE 5432
ENTRYPOINT ["./start-pgbouncer.sh"]