FROM haproxy:2.9-alpine

LABEL maintainer="Cockroach Labs PS <lee.long@cockroachlabs.com>"

# Copy config
COPY ./haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

# Optional documentation ports
EXPOSE 5432 8404

# Simple container healthcheck: is HAProxy listening on 5432?
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD nc -z 127.0.0.1 5432 || exit 1