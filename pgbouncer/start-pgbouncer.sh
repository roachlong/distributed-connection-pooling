#!/bin/bash

PROG="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PGBOUNCER_CLIENT="postgres"
CLIENT_PASSWORD="secret"
PGBOUNCER_SERVER="root"
PGBOUNCER_CONNECTIONS=10
HOST_IP="127.0.0.1"
HOST_PORT="26257"
DATABASE="postgres"

usage() {
    echo "USAGE: ${PROG}
    [--client-account <PGBOUNCER_CLIENT>
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
        output "Required parameter for '-${key}' not specified.\n"
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
                        output "Unknown option '${key:${keypos}}'.\n"
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

# Add or replace the user entry
if grep -qE "^\"${PGBOUNCER_CLIENT}\" " "${userlist}"; then
  tmp="$(mktemp)"
  awk -v u="${PGBOUNCER_CLIENT}" -v s="${CLIENT_PASSWORD}" \
    'BEGIN{q="\""} $0 ~ "^" q u q " " {print q u q " " q s q; next} {print}' \
    "${userlist}" > "${tmp}"
  mv "${tmp}" "${userlist}"
else
  printf "\"%s\" \"%s\"\n" "${PGBOUNCER_CLIENT}" "${CLIENT_PASSWORD}" >> "${userlist}"
fi

num_files=$(( (${PGBOUNCER_CONNECTIONS} / 64) + (${PGBOUNCER_CONNECTIONS} % 64 > 0) ))
pool_size=$(( (${PGBOUNCER_CONNECTIONS} / ${num_files}) + (${PGBOUNCER_CONNECTIONS} % ${num_files} > 0) ))
echo "creating ${num_files} instances with ${pool_size} connections each"

for (( i=1; i<=${num_files}; i++ )); do
    PGID=${i}
    cp ${SCRIPT_DIR}/pgbouncer.template ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%PGID%/${PGID}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%CLIENT%/${PGBOUNCER_CLIENT}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%SERVER%/${PGBOUNCER_SERVER}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%SIZE%/${pool_size}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%HOST_IP%/${HOST_IP}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%HOST_PORT%/${HOST_PORT}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    sed -i "s/%DATABASE%/${DATABASE}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    script_dir_esc=$(eval echo ${SCRIPT_DIR} | sed 's/\//\\\//g')
    sed -i "s/%SCRIPT_DIR%/${script_dir_esc}/g" ${SCRIPT_DIR}/pgbouncer.${PGID}.ini
    mkdir -p ${SCRIPT_DIR}/../run/${PGID}
done
chown -R postgres:postgres ${SCRIPT_DIR}

while true; do
    for FILE in ${SCRIPT_DIR}/*.ini; do
        pid=$(ps aux | grep ${FILE} | grep -v 'grep' | awk '{print $2}')
        if [ -z "${pid}" ]; then
            pgbouncer -d -u postgres ${FILE}
        fi
        sleep 5
    done
done
