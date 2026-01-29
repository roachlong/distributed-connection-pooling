#!/usr/bin/env python3
import argparse
import json
import math
import subprocess
import tempfile
import time
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SSH_OPTS = (
    "-o StrictHostKeyChecking=no "
    "-o UserKnownHostsFile=/dev/null "
    "-o LogLevel=ERROR "
    "-q"
)

# ----------------------------
# Phase policy
# ----------------------------

class PhasePolicy(str, Enum):
    SKIP = "skip"
    NEW = "new"
    REFRESH = "refresh"

# ----------------------------
# Shell helpers
# ----------------------------

def run(cmd: str, cwd: Optional[str] = None, check: bool = True) -> str:
    print(f"\n>>> {cmd}")
    p = subprocess.run(
        cmd,
        shell=True,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    print(p.stdout)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}")
    return p.stdout.strip()


def terraform_apply(tf_dir: str, tfvars: str) -> None:
    run(f"terraform -chdir={tf_dir} init")
    run(f"terraform -chdir={tf_dir} apply -var-file={tfvars} -auto-approve")


def terraform_output(tf_dir: str) -> Dict[str, Any]:
    out = run(f"terraform -chdir={tf_dir} output -json")
    return json.loads(out)


def ssh(host: str, ssh_user: str, ssh_key: str, remote_cmd: str, check: bool = True) -> str:
    return run(
        f"ssh -i {ssh_key} {SSH_OPTS} {ssh_user}@{host} {json.dumps(remote_cmd)}",
        check=check,
    )


def scp_file(host: str, ssh_user: str, ssh_key: str, local_path: Path, remote_path: str) -> None:
    run(
        f"scp -i {ssh_key} {SSH_OPTS} {local_path} {ssh_user}@{host}:/tmp/{local_path.name}"
    )
    ssh(host, ssh_user, ssh_key, f"sudo mv /tmp/{local_path.name} {remote_path}")


def scp_text(host: str, ssh_user: str, ssh_key: str, remote_path: str, content: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / Path(remote_path).name
        p.write_text(content)
        scp_file(host, ssh_user, ssh_key, p, remote_path)


def can_ssh(host: str, ssh_user: str, ssh_key: str, timeout: int = 5) -> bool:
    try:
        run(
            f"ssh -i {ssh_key} {SSH_OPTS} "
            f"-o ConnectTimeout={timeout} "
            f"{ssh_user}@{host} echo ok",
            check=True,
        )
        return True
    except Exception:
        return False


def pick_dcp_ssh_host(
    dcp_record: Dict[str, Any],
    ssh_user: str,
    ssh_key: str,
) -> str:
    """
    Try node public_ip first.
    If unreachable, fall back to region EIP.
    """
    node_ip = dcp_record.get("public_ip")
    eip = dcp_record.get("eip_public_ip")

    if node_ip and can_ssh(node_ip, ssh_user, ssh_key):
        return node_ip

    if eip and can_ssh(eip, ssh_user, ssh_key):
        return eip

    raise RuntimeError(
        f"Cannot SSH to DCP node {dcp_record.get('id')} "
        f"via public_ip or eip_public_ip"
    )


# ----------------------------
# Wait helpers
# ----------------------------

def wait_for_ssh(host: str, ssh_user: str, ssh_key: str, timeout: int = 300) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        out = ssh(host, ssh_user, ssh_key, "echo ok", check=False)
        if "ok" in out:
            return
        time.sleep(5)
    raise RuntimeError(f"Timed out waiting for SSH on {host}")


def wait_for_cloud_init(
    host: str,
    ssh_user: str,
    ssh_key: str,
) -> None:
    print(f"⏳ Waiting for cloud-init to finish on {host}...")
    try:
        ssh(
            host,
            ssh_user,
            ssh_key,
            "sudo cloud-init status --wait > /dev/null",
            check=True,
        )
        print("✅ cloud-init finished")
    except Exception as e:
        raise RuntimeError(f"cloud-init did not complete on {host}") from e


def wait_for_crdb_listener(host: str, ssh_user: str, ssh_key: str, timeout=300):
    print(f"⏳ Waiting for CockroachDB to listen on {host}:26257...")
    deadline = time.time() + timeout

    while time.time() < deadline:
        out = ssh(
            host,
            ssh_user,
            ssh_key,
            "ss -ltn | grep ':26257'",
            check=False,
        )
        if out.strip():
            print("✅ CockroachDB port is listening")
            return
        time.sleep(5)

    raise RuntimeError("CockroachDB never started listening on 26257")


def wait_for_expected_nodes(
    seed_host: str,
    ssh_user: str,
    ssh_key: str,
    expected_nodes: int,
    timeout: int = 600,
) -> None:
    print(f"⏳ Waiting for {expected_nodes} Cockroach nodes to be live...")
    deadline = time.time() + timeout

    while time.time() < deadline:
        out = ssh(
            seed_host,
            ssh_user,
            ssh_key,
            "sudo -u cockroach cockroach node status "
            "--certs-dir=/var/lib/cockroach/certs "
            "--format=tsv",
            check=False,
        )

        if "cannot dial server" in out or "Failed running" in out:
            print("   Cockroach not ready yet")
            time.sleep(5)
            continue

        lines = [l for l in out.splitlines() if l.strip() and not l.startswith("Warning:")]
        if len(lines) < 2:
            time.sleep(5)
            continue

        header = lines[0].split("\t")
        rows = [l.split("\t") for l in lines[1:]]

        if "is_live" not in header:
            print(f"   Unexpected output, retrying: {header}")
            time.sleep(5)
            continue
        
        try:
            is_live_idx = header.index("is_live")
        except ValueError:
            raise RuntimeError(f"Unexpected node status header: {header}")

        live = [r for r in rows if len(r) > is_live_idx and r[is_live_idx] == "true"]

        print(f"   seen={len(rows)} live={len(live)}")

        if len(live) >= expected_nodes:
            print("✅ All expected nodes are live")
            return

        time.sleep(5)

    raise RuntimeError("Timed out waiting for all Cockroach nodes to be live")


# ----------------------------
# Cert generation
# ----------------------------

def ensure_ca(certs_dir: Path, ca_key: Path) -> None:
    certs_dir.mkdir(parents=True, exist_ok=True)
    ca_crt = certs_dir / "ca.crt"
    if ca_key.exists() and ca_crt.exists():
        print("🔐 Reusing existing CA")
        return
    print("🔐 Creating new CA")
    run(f"cockroach cert create-ca --certs-dir={certs_dir} --ca-key={ca_key}")


def create_client_cert(certs_dir: Path, ca_key: Path, username: str) -> None:
    (certs_dir / f"client.{username}.crt").unlink(missing_ok=True)
    (certs_dir / f"client.{username}.key").unlink(missing_ok=True)
    run(f"cockroach cert create-client {username} --certs-dir={certs_dir} --ca-key={ca_key}")


def create_crdb_node_cert(node: Dict[str, Any], dns_zone: str, certs_dir: Path, ca_key: Path) -> None:
    """
    Writes certs_dir/node.crt and certs_dir/node.key for this node.
    Include db.<region>.<zone> SAN so clients can verify-full against the VIP DNS name.
    """
    (certs_dir / "node.crt").unlink(missing_ok=True)
    (certs_dir / "node.key").unlink(missing_ok=True)

    run(
        "cockroach cert create-node "
        f"{node['name']} "
        f"db.{node['region']}.{dns_zone} "
        f"{node['private_ip']} "
        "localhost "
        f"--certs-dir={certs_dir} "
        f"--ca-key={ca_key}"
    )


def create_pgbouncer_server_cert(
    region: str,
    dns_zone: str,
    certs_dir: Path,
    ca_key: Path,
) -> tuple[Path, Path]:
    """
    Create a TLS server cert for PgBouncer.
    Produces:
      server.pgbouncer.crt
      server.pgbouncer.key

    SANs include:
      - pgb.<region>.<dns_zone>
      - localhost
    """
    key = certs_dir / "server.pgbouncer.key"
    crt = certs_dir / "server.pgbouncer.crt"
    csr = certs_dir / "server.pgbouncer.csr"
    cnf = certs_dir / "server.pgbouncer.cnf"

    cnf.write_text(f"""
[ req ]
default_bits        = 4096
prompt              = no
default_md          = sha256
distinguished_name  = dn
req_extensions      = req_ext

[ dn ]
CN = pgbouncer

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = pgb.{region}.{dns_zone}
DNS.2 = localhost
""".strip())

    run(f"openssl genrsa -out {key} 4096")
    run(f"openssl req -new -key {key} -out {csr} -config {cnf}")
    run(
        f"openssl x509 -req -in {csr} "
        f"-CA {certs_dir/'ca.crt'} "
        f"-CAkey {ca_key} "
        f"-CAcreateserial "
        f"-out {crt} "
        f"-days 365 "
        f"-sha256 "
        f"-extensions req_ext "
        f"-extfile {cnf}"
    )

    return crt, key


# ----------------------------
# Remote installs
# ----------------------------

def install_crdb_certs(node: Dict[str, Any], ssh_user: str, ssh_key: str, certs_dir: Path) -> None:
    host = node["public_dns"]
    # Copy CA + node.* to node, then move into /var/lib/cockroach/certs
    run(f"scp -i {ssh_key} {SSH_OPTS} {certs_dir/'ca.crt'} {ssh_user}@{host}:/tmp/ca.crt")
    run(f"scp -i {ssh_key} {SSH_OPTS} {certs_dir/'node.crt'} {ssh_user}@{host}:/tmp/node.crt")
    run(f"scp -i {ssh_key} {SSH_OPTS} {certs_dir/'node.key'} {ssh_user}@{host}:/tmp/node.key")
    run(f"scp -i {ssh_key} {SSH_OPTS} {certs_dir/'client.root.crt'} {ssh_user}@{host}:/tmp/client.root.crt")
    run(f"scp -i {ssh_key} {SSH_OPTS} {certs_dir/'client.root.key'} {ssh_user}@{host}:/tmp/client.root.key")
    run(f"""
ssh -i {ssh_key} {SSH_OPTS} {ssh_user}@{host} <<'EOF'
sudo mkdir -p /var/lib/cockroach/certs
sudo mv /tmp/ca.crt /tmp/node.crt /tmp/node.key /tmp/client.root.crt /tmp/client.root.key /var/lib/cockroach/certs/
sudo chown -R cockroach:cockroach /var/lib/cockroach
sudo chmod 0644 /var/lib/cockroach/certs/*.crt
sudo chmod 0600 /var/lib/cockroach/certs/*.key
EOF
""")


def install_and_start_crdb_service(
    nodes: List[Dict[str, Any]],
    ssh_user: str,
    ssh_key: str,
    restart: bool,
    db_port: int,
    ui_port: int,
) -> None:
    """
    Creates /etc/systemd/system/cockroach.service on each node and
    starts or restarts it depending on `restart`.

    - restart=False → start only if not running
    - restart=True  → force restart
    """
    join = ",".join(f"{n['name']}:{db_port}" for n in nodes)
    total_nodes = len(nodes)

    action = "restart" if restart else "start"

    for node in nodes:
        host = node["public_dns"]
        name = node["name"]
        region = node.get("region", "unknown")
        az = node.get("az", "") or node.get("availability_zone", "")

        if total_nodes == 1:
            exec_start = (
                "/usr/local/bin/cockroach start-single-node "
                "--certs-dir=/var/lib/cockroach/certs "
                "--store=/mnt/cockroach-data "
                f"--listen-addr=0.0.0.0:{db_port} "
                f"--advertise-addr={name}:{db_port} "
                f"--http-addr=0.0.0.0:{ui_port} "
                f"--locality=region={region},zone={az}"
            )
        else:
            exec_start = (
                "/usr/local/bin/cockroach start "
                "--certs-dir=/var/lib/cockroach/certs "
                "--store=/mnt/cockroach-data "
                f"--listen-addr=0.0.0.0:{db_port} "
                f"--advertise-addr={name}:{db_port} "
                f"--http-addr=0.0.0.0:{ui_port} "
                f"--join={join} "
                f"--locality=region={region},zone={az}"
            )

        run(f"""
ssh -i {ssh_key} {SSH_OPTS} {ssh_user}@{host} <<'EOF'
sudo tee /etc/systemd/system/cockroach.service > /dev/null <<SERVICE
[Unit]
Description=CockroachDB
After=network-online.target
Wants=network-online.target

[Service]
User=cockroach
ExecStart={exec_start}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable cockroach
sudo systemctl {action} cockroach
EOF
""")


def init_cluster(seed_node: Dict[str, Any], ssh_user: str, ssh_key: str, db_port: int) -> None:
    """
    Idempotent init: if already initialized, ignore the error.
    We use certs_dir client certs locally (typically client.root.*).
    """
    seed = f"{seed_node['name']}:{db_port}"
    cmd = (
        "sudo -u cockroach cockroach init "
        "--certs-dir=/var/lib/cockroach/certs "
        f"--host={seed}"
    )
    out = ssh(seed_node["public_dns"], ssh_user, ssh_key, cmd)
    if "already initialized" in out.lower() or "cluster has already been initialized" in out.lower():
        print("ℹ️ Cluster already initialized, continuing")
    elif "successfully initialized" in out.lower() or "initialized" in out.lower():
        print("✅ Cluster initialized")
    else:
        # Cockroach init can be chatty; only fail if nonzero and not the known message
        # run(..., check=False) already; keep conservative:
        pass


# ----------------------------
# SQL bootstrap
# ----------------------------

def sql_exec_on_seed(seed_host: str, ssh_user: str, ssh_key: str, sql: str, db_port: int) -> None:
    cmd = (
        "sudo -u cockroach cockroach sql "
        "--certs-dir=/var/lib/cockroach/certs "
        f"--host=localhost:{db_port} "
        f"-e {json.dumps(sql)}"
    )
    ssh(seed_host, ssh_user, ssh_key, cmd)


def ensure_db_and_user(seed_host: str, ssh_user: str, ssh_key: str, dbname: str, username: str,
                       password: Optional[str], make_admin: bool, db_port: int) -> None:
    stmts = [
        f"CREATE DATABASE IF NOT EXISTS {dbname};",
        f"CREATE USER IF NOT EXISTS {username};",
    ]
    if password is not None:
        # password mode convenience
        stmts.append(f"ALTER USER {username} WITH PASSWORD {json.dumps(password)};")
    if make_admin:
        stmts.append(f"GRANT admin TO {username};")
    sql_exec_on_seed(seed_host, ssh_user, ssh_key, " ".join(stmts), db_port)


# ----------------------------
# PgBouncer + HAProxy
# ----------------------------

def install_pgb_certs_on_dcp(
    dcp_host: str,
    ssh_user: str,
    ssh_key: str,
    certs_dir: Path,
    pgb_client_user: str,
    pgb_server_user: str,
) -> None:
    """
    Copy:
      - ca.crt
      - server.pgbouncer.crt/key  (PgBouncer server identity)
      - client.<pgb_server_user>.crt/key  (PgBouncer backend client identity for CRDB)
    Into /etc/pgbouncer/certs on each DCP node.
    """
    ssh(dcp_host, ssh_user, ssh_key,
        "sudo mkdir -p /etc/pgbouncer/certs && sudo chown -R postgres:postgres /etc/pgbouncer && sudo chmod 700 /etc/pgbouncer/certs")

    for f in [
        certs_dir / "ca.crt",
        certs_dir / "server.pgbouncer.crt",
        certs_dir / "server.pgbouncer.key",
        certs_dir / f"client.{pgb_server_user}.crt",
        certs_dir / f"client.{pgb_server_user}.key",
    ]:
        scp_file(dcp_host, ssh_user, ssh_key, f, f"/etc/pgbouncer/certs/{f.name}")

    ssh(dcp_host, ssh_user, ssh_key,
        "sudo chown -R postgres:postgres /etc/pgbouncer && "
        "sudo find /etc/pgbouncer/certs -type f -name '*.crt' -exec chmod 0644 {} + && "
        "sudo find /etc/pgbouncer/certs -type f -name '*.key' -exec chmod 0600 {} +"
    )


def compute_pgb_connections(total_conn: int, pgb_nodes: int) -> int:
    # Divide across PgBouncer nodes
    per_node = max(4, math.ceil(total_conn / pgb_nodes))
    return per_node


def render_runner_env(
    client_account: str,
    server_account: str,
    auth_mode: str,
    client_password: str | None,
    num_connections: int,
    database: str,
) -> str:
    lines = [
        f"PGB_CLIENT_ACCOUNT={client_account}",
        f"PGB_SERVER_ACCOUNT={server_account}",
        f"PGB_AUTH_MODE={auth_mode}",
        f"PGB_NUM_CONNECTIONS={num_connections}",
        f"PGB_DATABASE={database}",
    ]

    if auth_mode == "password":
        lines.append(f"PGB_CLIENT_PASSWORD={client_password}")
    else:
        # avoid stale password lingering
        lines.append("PGB_CLIENT_PASSWORD=")

    return "\n".join(lines) + "\n"


def push_runner_env(dcp_host: str, ssh_user: str, ssh_key: str, env_text: str) -> None:
    scp_text(
        host=dcp_host,
        ssh_user=ssh_user,
        ssh_key=ssh_key,
        remote_path="/etc/pgbouncer/runner.env",
        content=env_text,
    )

    ssh(dcp_host, ssh_user, ssh_key, "sudo chown postgres:postgres /etc/pgbouncer/runner.env")
    ssh(dcp_host, ssh_user, ssh_key, "sudo chmod 600 /etc/pgbouncer/runner.env")


def render_haproxy_cfg(pgbouncer_ips: List[str], backend_ips: List[str], pgb_port: int, db_port: int, ui_port: int) -> str:
    lines: List[str] = []
    lines += [
        "global",
        "  maxconn 200000",
        "  log /dev/log local0",
        "  daemon",
        "",
        "defaults",
        "  mode tcp",
        "  log global",
        "  option tcplog",
        "  timeout connect 5s",
        "  timeout client  180s",
        "  timeout server  180s",
        "",
        "frontend pgb_front",
        f"  bind *:{pgb_port}",
        "  default_backend pgb_pool",
        "",
        "backend pgb_pool",
        "  balance roundrobin",
        "  option tcp-check",
        "  default-server inter 2s fall 3 rise 2",
    ]
    for i, ip in enumerate(pgbouncer_ips, start=1):
        lines.append(f"  server pgb{i} {ip}:6432 check")

    lines += [
        "",
        "frontend db_front",
        f"  bind *:{db_port}",
        "  default_backend db_pool",
        "",
        "backend db_pool",
        "  balance roundrobin",
        "  option tcp-check",
        "  default-server inter 2s fall 3 rise 2",
    ]
    for i, ip in enumerate(backend_ips, start=1):
        lines.append(f"  server crdb{i} {ip}:{db_port} check")

    lines += [
        "",
        "frontend crdb_admin",
        f"  bind *:{ui_port}",
        "  default_backend crdb_admin_pool",
        "",
        "backend crdb_admin_pool",
        "  balance roundrobin",
        "  option tcp-check",
        "  default-server inter 2s fall 3 rise 2",
    ]
    for i, ip in enumerate(backend_ips, start=1):
        lines.append(f"  server admin{i} {ip}:{ui_port} check")

    lines.append("")
    return "\n".join(lines)


def push_haproxy_cfg(dcp_host: str, ssh_user: str, ssh_key: str, cfg: str) -> None:
    scp_text(dcp_host, ssh_user, ssh_key, "/etc/haproxy/haproxy.cfg", cfg)
    ssh(dcp_host, ssh_user, ssh_key, "sudo haproxy -c -f /etc/haproxy/haproxy.cfg")
    ssh(dcp_host, ssh_user, ssh_key, "sudo systemctl restart haproxy")


def start_pgbouncer_runner(dcp_host: str, ssh_user: str, ssh_key: str) -> None:
    ssh(dcp_host, ssh_user, ssh_key, "sudo systemctl daemon-reload")
    ssh(dcp_host, ssh_user, ssh_key, "sudo systemctl restart pgbouncer-runner")


# ----------------------------
# Validation
# ----------------------------

def validate_region_cert(region: str, dns_zone: str, certs_dir: Path, pgb_client_user: str, database: str, pgb_port: int, db_port: int) -> None:
    # Direct DB via VIP DNS
    db_host = f"db.{region}.{dns_zone}:{db_port}"
    run(f"cockroach sql --certs-dir={certs_dir} --host={db_host} -e 'SELECT 1;'")

    # Through PgBouncer via VIP DNS (client cert)
    pgb_host = f"pgb.{region}.{dns_zone}"
    run(
        "psql "
        f"\"host={pgb_host} port={pgb_port} dbname={database} sslmode=verify-full "
        f"sslrootcert={certs_dir/'ca.crt'} "
        f"sslcert={certs_dir/f'client.{pgb_client_user}.crt'} "
        f"sslkey={certs_dir/f'client.{pgb_client_user}.key'}\" "
        "-c 'SELECT 1;'"
    )


def validate_region_password(region: str, dns_zone: str, username: str, password: str, database: str, pgb_port: int) -> None:
    pgb_host = f"pgb.{region}.{dns_zone}"
    # sslmode=require is enough for TLS-on; switch to verify-full for strict hostname checks
    run(
        "psql "
        f"\"host={pgb_host} port={pgb_port} dbname={database} user={username} password={password} sslmode=require\" "
        "-c 'SELECT 1;'"
    )


# ----------------------------
# Argument parsing
# ----------------------------

def parse_args():
    parser = argparse.ArgumentParser()

    parser.add_argument("--ssh-user", default="debian")
    parser.add_argument("--ssh-key", default="./my-safe-directory/dev")

    # Infra
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--terraform-dir", default="./terraform/aws")
    parser.add_argument("--tfvars-file", default="crdb-dcp-test.tfvars")

    # Certs
    parser.add_argument("--ca-cert", action="store_true")
    parser.add_argument("--node-certs", action="store_true")
    parser.add_argument(
        "--root-cert",
        choices=[PhasePolicy.NEW, PhasePolicy.REFRESH, PhasePolicy.SKIP],
        default=PhasePolicy.NEW,
    )
    parser.add_argument("--dns-zone", required=True)
    parser.add_argument("--certs-dir", required=True)
    parser.add_argument("--ca-key", default="./my-safe-directory/ca.key")

    # Cockroach
    parser.add_argument(
        "--start-nodes",
        choices=[PhasePolicy.NEW, PhasePolicy.REFRESH, PhasePolicy.SKIP],
        default=PhasePolicy.NEW,
    )
    parser.add_argument("--skip-init", action="store_true")
    parser.add_argument("--sql-users", action="store_true")

    # PgBouncer / HAProxy
    parser.add_argument("--skip-pgbouncer", action="store_true")
    parser.add_argument("--skip-haproxy", action="store_true")
    parser.add_argument("--auth-mode", choices=["password", "cert"], required=True)
    parser.add_argument("--num-connections", type=int, default=10)
    parser.add_argument("--database", default="defaultdb")
    parser.add_argument("--pgb-port", type=int, default=5432)
    parser.add_argument("--db-port", type=int, default=26257)
    parser.add_argument("--ui-port", type=int, default=8080)

    parser.add_argument("--pgb-client-user", default="postgres")
    parser.add_argument("--pgb-server-user", default="pgb")
    parser.add_argument("--password", default="appuser-password")

    # Validation
    parser.add_argument("--skip-validation", action="store_true")

    return parser.parse_args()


# ----------------------------
# Main orchestration
# ----------------------------

def main():
    args = parse_args()

    # 1) Terraform
    if args.apply:
        terraform_apply(args.terraform_dir, args.tfvars_file)

    outputs = terraform_output(args.terraform_dir)
    cockroach_nodes_by_region = outputs["cockroach_nodes"]["value"]
    dcp_endpoints_by_region = outputs["dcp_endpoints"]["value"]

    # Flatten nodes
    nodes: List[Dict[str, Any]] = []
    for region, region_nodes in cockroach_nodes_by_region.items():
        for n in region_nodes:
            n["region"] = region
            nodes.append(n)

    dcp_nodes: List[Dict[str, Any]] = []
    for region, region_nodes in dcp_endpoints_by_region.items():
        for p in region_nodes:
            p["region"] = region
            dcp_nodes.append(p)

    # Group
    crdb_by_region: Dict[str, List[Dict[str, Any]]] = {}
    for n in nodes:
        crdb_by_region.setdefault(n["region"], []).append(n)

    dcp_by_region: Dict[str, List[Dict[str, Any]]] = {}
    for p in dcp_nodes:
        dcp_by_region.setdefault(p["region"], []).append(p)

    certs_dir = Path(args.certs_dir).expanduser().resolve()
    ca_key = Path(args.ca_key).expanduser().resolve()

    # 2) CA
    if args.ca_cert:
        ensure_ca(certs_dir, ca_key)
    else:
        if not ca_key.exists():
            raise RuntimeError("CA does not exist and --ca-cert not specified")

    # 3) root and dcp certs
    if args.root_cert != PhasePolicy.SKIP:
        if args.root_cert == PhasePolicy.REFRESH or not (certs_dir / "client.root.crt").exists():
            create_client_cert(certs_dir, ca_key, "root")

    if args.auth_mode == "cert" and args.sql_users:
        if not (certs_dir / f"client.{args.pgb_server_user}.crt").exists():
            create_client_cert(certs_dir, ca_key, args.pgb_server_user)  # pgb -> crdb
        if not (certs_dir / f"client.{args.pgb_client_user}.crt").exists():
            create_client_cert(certs_dir, ca_key, args.pgb_client_user)  # client -> pgb

    if args.start_nodes != PhasePolicy.SKIP:
        # 4) node certs
        for node in nodes:
            wait_for_ssh(node["public_dns"], args.ssh_user, args.ssh_key, timeout=300)
            wait_for_cloud_init(node["public_dns"], args.ssh_user, args.ssh_key)
            if args.node_certs:
                create_crdb_node_cert(node, args.dns_zone, certs_dir, ca_key)
            install_crdb_certs(node, args.ssh_user, args.ssh_key, certs_dir)

        # 5) start Cockroach nodes
        install_and_start_crdb_service(
            nodes,
            args.ssh_user,
            args.ssh_key,
            restart=(args.start_nodes == PhasePolicy.REFRESH),
            db_port=args.db_port,
            ui_port=args.ui_port,
        )

        wait_for_crdb_listener(
            nodes[0]["public_dns"],
            args.ssh_user,
            args.ssh_key,
        )

    # 6) init cluster
    if not args.skip_init and len(nodes) > 1:
        init_cluster(nodes[0], args.ssh_user, args.ssh_key, args.db_port)

    wait_for_expected_nodes(
        seed_host=nodes[0]["public_dns"],
        ssh_user=args.ssh_user,
        ssh_key=args.ssh_key,
        expected_nodes=len(nodes),
    )

    # 7) SQL users / DBs
    if args.sql_users:
        if args.auth_mode == "cert":
            ensure_db_and_user(
                nodes[0]["public_dns"],
                args.ssh_user,
                args.ssh_key,
                args.database,
                args.pgb_server_user,
                password=None,
                make_admin=True,
                db_port=args.db_port,
            )
            ensure_db_and_user(
                nodes[0]["public_dns"],
                args.ssh_user,
                args.ssh_key,
                args.database,
                args.pgb_client_user,
                password=None,
                make_admin=False,
                db_port=args.db_port,
            )
        else:
            ensure_db_and_user(
                nodes[0]["public_dns"],
                args.ssh_user,
                args.ssh_key,
                args.database,
                args.pgb_client_user,
                password=args.password,
                make_admin=False,
                db_port=args.db_port,
            )

    # 8) PgBouncer
    if not args.skip_pgbouncer:
        total_pgb_nodes = sum(len(region_proxies) for region_proxies in dcp_by_region.values())
        per_node_conn = compute_pgb_connections(args.num_connections, total_pgb_nodes)

        env_text = render_runner_env(
            client_account=args.pgb_client_user,
            server_account=args.pgb_server_user,
            auth_mode=args.auth_mode,
            client_password=args.password,
            num_connections=per_node_conn,
            database=args.database,
        )

        for region, region_proxies in dcp_by_region.items():
            if args.auth_mode == "cert":
                create_pgbouncer_server_cert(region, args.dns_zone, certs_dir, ca_key)

            for p in region_proxies:
                dcp_host = pick_dcp_ssh_host(p, args.ssh_user, args.ssh_key)
                wait_for_ssh(dcp_host, args.ssh_user, args.ssh_key, timeout=300)
                wait_for_cloud_init(dcp_host, args.ssh_user, args.ssh_key)
                push_runner_env(dcp_host, args.ssh_user, args.ssh_key, env_text)

                if args.auth_mode == "cert":
                    install_pgb_certs_on_dcp(
                        dcp_host,
                        args.ssh_user,
                        args.ssh_key,
                        certs_dir,
                        args.pgb_client_user,
                        args.pgb_server_user,
                    )

                start_pgbouncer_runner(dcp_host, args.ssh_user, args.ssh_key)

    # 9) HAProxy
    if not args.skip_haproxy:
        for region, region_proxies in dcp_by_region.items():
            pgb_ips = [p["private_ip"] for p in region_proxies]
            db_ips = [n["private_ip"] for n in crdb_by_region.get(region, [])]
            if not db_ips:
                raise RuntimeError(f"No Cockroach nodes found for region {region}")

            cfg = render_haproxy_cfg(pgb_ips, db_ips, pgb_port=args.pgb_port, db_port=args.db_port, ui_port=args.ui_port)
            for p in region_proxies:
                dcp_host = pick_dcp_ssh_host(p, args.ssh_user, args.ssh_key)
                push_haproxy_cfg(dcp_host, args.ssh_user, args.ssh_key, cfg)

    # 10) Validation
    if not args.skip_validation:
        for region in sorted(dcp_by_region.keys()):
            if args.auth_mode == "cert":
                validate_region_cert(region, args.dns_zone, certs_dir, args.pgb_client_user, args.database, args.pgb_port, args.db_port)
            else:
                validate_region_password(region, args.dns_zone, args.pgb_client_user, args.password, args.database, args.pgb_port, args.db_port)

    print("\n✅ Bootstrap complete: Cockroach + PgBouncer + HAProxy configured and validated")


if __name__ == "__main__":
    main()
