#!/bin/bash

PROG="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PGBOUNCER_CLIENT="postgres"
AUTH_MODE="password"
CLIENT_PASSWORD="secret"
PGBOUNCER_SERVER="root"
PGBOUNCER_CONNECTIONS=10
HOST_IP="127.0.0.1"
HOST_PORT="26257"
DATABASE="postgres"

usage() {
    echo "USAGE: ${PROG}
    [--client-account <PGBOUNCER_CLIENT>
    [--auth-mode <AUTH_MODE>]
    [--client-password <CLIENT_PASSWORD>
    [--server-account <PGBOUNCER_SERVER>]
    [--num-connections <PGBOUNCER_CONNECTIONS>]
    [--host-ip <HOST_IP>]
    [--host-port <HOST_PORT>]
    [--database <DATABASE>]
"
}

help_exit() {
    usage
    echo "This is a utility script to create and start pgbouncer instances supporting a single connection pool
Options:
    -c, --client-account PGBOUNCER_CLIENT
        the username we expect to authenticate from the frontend client application, defaults to postgres
    -a, --auth-mode AUTH_MODE
        the authentication mode used by pgbouncer to connect to the backend database server, either cert or password, defaults to password
    -p, --client-password CLIENT_PASSWORD
        the password used to authenticate the frontend client application, defaults to secret
    -s, --server-account PGBOUNCER_SERVER
        the username that will be authenticated against the backend database server, defaults to root
    -n, --num-connections PGBOUNCER_CONNECTIONS
        the maximum number of connections that will be served by this pgbouncer pool, defaults to 10
    -i, --host-ip HOST_IP
        the ip of the host machine where the database for this pgbouncer pool resides, defaults to 127.0.0.1
    -o, --host-port HOST_PORT
        the port of the host machine where the database for this pgbouncer pool resides, defaults to 26257
    -d, --database DATABASE
        the name of the database that will be served by this pgbouncer pool, defaults to postgres
    -h, --help
        output this help message
"
    exit 0
}

assign() {
    key="${1}"
    value="${key#*=}"
    if [[ "${value}" != "${key}" ]]; then
        # key was of the form 'key=value'
        echo "${value}"
        return 0
    elif [[ "x${2}" != "x" ]]; then
        echo "${2}"
        return 2
    else
        echo "Required parameter for '-${key}' not specified.\n"
        usage
        exit 1
    fi
    keypos=$keylen
}

while [[ $# -ge 1 ]]; do
    key="${1}"
    case $key in
        -*)
            keylen=${#key}
            keypos=1
            while [[ $keypos -lt $keylen ]]; do
                case ${key:${keypos}} in
                    c|-client-account)
                        PGBOUNCER_CLIENT=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    a|-auth-mode)
                        AUTH_MODE=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    p|-client-password)
                        CLIENT_PASSWORD=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    s|-server-account)
                        PGBOUNCER_SERVER=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    n|-num-connections)
                        PGBOUNCER_CONNECTIONS=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    i|-host-ip)
                        HOST_IP=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    o|-host-port)
                        HOST_PORT=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    d|-database)
                        DATABASE=$(assign "${key:${keypos}}" "${2}")
                        if [[ $? -eq 2 ]]; then shift; fi
                        keypos=$keylen
                    ;;
                    h*|-help)
                        help_exit
                    ;;
                    *)
                        echo "Unknown option '${key:${keypos}}'.\n"
                        usage
                        exit 1
                    ;;
                esac
                ((keypos++))
            done
        ;;
    esac
    shift
done

echo "executing ${PROG} from ${SCRIPT_DIR} with:
    PGBOUNCER_CLIENT=${PGBOUNCER_CLIENT}
    AUTH_MODE=${AUTH_MODE}
    CLIENT_PASSWORD=******
    PGBOUNCER_SERVER=${PGBOUNCER_SERVER}
    PGBOUNCER_CONNECTIONS=${PGBOUNCER_CONNECTIONS}
    HOST_IP=${HOST_IP}
    HOST_PORT=${HOST_PORT}
    DATABASE=${DATABASE}
"

userlist="${SCRIPT_DIR}/userlist.txt"
mkdir -p "${SCRIPT_DIR}"
touch "${userlist}"
chmod 600 "${userlist}"

if [[ "${AUTH_MODE}" == "cert" ]]; then
    # Add or replace the user entry WITHOUT a password
    if grep -qE "^\"${PGBOUNCER_CLIENT}\" " "${userlist}"; then
        tmp="$(mktemp)"
        awk -v u="${PGBOUNCER_CLIENT}" -v s="" \
            'BEGIN{q="\""} $0 ~ "^" q u q " " {print q u q " " q s q; next} {print}' \
            "${userlist}" > "${tmp}"
        mv "${tmp}" "${userlist}"
    else
        printf "\"%s\" \"%s\"\n" "${PGBOUNCER_CLIENT}" "" >> "${userlist}"
    fi
else
    # Add or replace the user entry WITH a password
    if grep -qE "^\"${PGBOUNCER_CLIENT}\" " "${userlist}"; then
        tmp="$(mktemp)"
        awk -v u="${PGBOUNCER_CLIENT}" -v s="${CLIENT_PASSWORD}" \
            'BEGIN{q="\""} $0 ~ "^" q u q " " {print q u q " " q s q; next} {print}' \
            "${userlist}" > "${tmp}"
        mv "${tmp}" "${userlist}"
    else
        printf "\"%s\" \"%s\"\n" "${PGBOUNCER_CLIENT}" "${CLIENT_PASSWORD}" >> "${userlist}"
    fi
fi

num_files=$(( (${PGBOUNCER_CONNECTIONS} / 64) + (${PGBOUNCER_CONNECTIONS} % 64 > 0) ))
pool_size=$(( (${PGBOUNCER_CONNECTIONS} / ${num_files}) + (${PGBOUNCER_CONNECTIONS} % ${num_files} > 0) ))
echo "creating ${num_files} instances with ${pool_size} connections each"

for (( i=1; i<=${num_files}; i++ )); do
    PGID=${i}
    cp ${SCRIPT_DIR}/pgbouncer.template ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%CLIENT%/${PGBOUNCER_CLIENT}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%DATABASE%/${DATABASE}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%HOST_IP%/${HOST_IP}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%HOST_PORT%/${HOST_PORT}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%PGID%/${PGID}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%SIZE%/${pool_size}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini

    if [[ "${AUTH_MODE}" == "cert" ]]; then
        sed -i "s/^auth_type =.*/auth_type = cert/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/%SERVER_USER%/user=${PGBOUNCER_SERVER}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^client_tls_sslmode =.*/client_tls_sslmode = verify-full/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^; client_tls_ca_file =.*/client_tls_ca_file = \/etc\/pgbouncer\/certs\/ca.crt/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^; client_tls_key_file =.*/client_tls_key_file = \/etc\/pgbouncer\/certs\/server.pgbouncer.key/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^; client_tls_cert_file =.*/client_tls_cert_file = \/etc\/pgbouncer\/certs\/server.pgbouncer.crt/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^server_tls_sslmode =.*/server_tls_sslmode = verify-full/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^; server_tls_ca_file =.*/server_tls_ca_file = \/etc\/pgbouncer\/certs\/ca.crt/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^; server_tls_key_file =.*/server_tls_key_file = \/etc\/pgbouncer\/certs\/client.${PGBOUNCER_SERVER}.key/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
        sed -i "s/^; server_tls_cert_file =.*/server_tls_cert_file = \/etc\/pgbouncer\/certs\/client.${PGBOUNCER_SERVER}.crt/" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    fi

    script_dir_esc=$(eval echo ${SCRIPT_DIR} | sed 's/\//\\\//g')
    sed -i "s/%SCRIPT_DIR%/${script_dir_esc}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    mkdir -p /var/run/pgbouncer/${PGID}
done
chown -R postgres:postgres ${SCRIPT_DIR}

while true; do
    for FILE in ${SCRIPT_DIR}/pgbouncer.*.ini; do
        pid=$(ps aux | grep ${FILE} | grep -v 'grep' | awk '{print $2}')
        if [ -z "${pid}" ]; then
            pgbouncer -d -u postgres ${FILE}
        fi
        sleep 5
    done
done
