FROM jrei/systemd-ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
       pacemaker pcs corosync fence-agents \
       resource-agents-base resource-agents-common resource-agents-extra \
       iproute2 iputils-ping net-tools curl vim less haproxy \
    && apt-get clean && rm -rf /var/lib/apt/lists/*