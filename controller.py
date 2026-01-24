#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
import tempfile
from pathlib import Path
from typing import Dict, List, Any, Tuple



# ----------------------------
# Helpers
# ----------------------------

def run(cmd: str, cwd: str | None = None, check: bool = True) -> str:
    print(f"\n>>> {cmd}")
    result = subprocess.run(
        cmd,
        shell=True,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    print(result.stdout)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}")
    return result.stdout.strip()


def terraform_apply(tf_dir: str, tf_vars: str) -> None:
    run(f"terraform -chdir={tf_dir} init")
    run(f"terraform -chdir={tf_dir} apply -var-file={tf_vars} -auto-approve")


def terraform_output(tf_dir: str) -> Dict[str, Any]:
    out = run(f"terraform -chdir={tf_dir} output -json")
    return json.loads(out)


def scp_text(host: str, ssh_user: str, ssh_key: str, remote_path: str, content: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        local = Path(td) / Path(remote_path).name
        local.write_text(content)
        run(f"scp -i {ssh_key} {local} {ssh_user}@{host}:/tmp/{local.name}")
        run(f"""
ssh -i {ssh_key} {ssh_user}@{host} <<'EOF'
sudo mv /tmp/{local.name} {remote_path}
EOF
""")


def scp_file(host: str, ssh_user: str, ssh_key: str, local_path: Path, remote_path: str) -> None:
    run(f"scp -i {ssh_key} {local_path} {ssh_user}@{host}:/tmp/{local_path.name}")
    run(f"""
ssh -i {ssh_key} {ssh_user}@{host} <<'EOF'
sudo mv /tmp/{local_path.name} {remote_path}
EOF
""")


def ssh(host: str, ssh_user: str, ssh_key: str, remote_cmd: str, check: bool = True) -> str:
    return run(f"ssh -i {ssh_key} {ssh_user}@{host} {json.dumps(remote_cmd)}", check=check)


# ----------------------------
# Cert generation
# ----------------------------

def ensure_ca_and_clients(certs_dir: Path, ca_key: Path, create_client_users: List[str]) -> None:
    certs_dir.mkdir(parents=True, exist_ok=True)
    ca_crt = certs_dir / "ca.crt"

    # Create CA only if it does not already exist
    if not ca_key.exists() or not ca_crt.exists():
        print("🔐 Creating new CA")
        run(
            f"cockroach cert create-ca "
            f"--certs-dir={certs_dir} "
            f"--ca-key={ca_key}"
        )
    else:
        print("🔐 Reusing existing CA")

    # Always (re)create client certs (safe; distribute as needed)
    for user in create_client_users:
        (certs_dir / f"client.{user}.crt").unlink(missing_ok=True)
        (certs_dir / f"client.{user}.key").unlink(missing_ok=True)
        run(f"cockroach cert create-client {user} "
            f"--certs-dir={certs_dir} "
            f"--ca-key={ca_key}"
        )


def generate_crdb_node_cert(node: Dict[str, Any], dns_zone: str, certs_dir: Path, ca_key: Path) -> None:
    # Cockroach tool writes node.crt/node.key
    (certs_dir / "node.crt").unlink(missing_ok=True)
    (certs_dir / "node.key").unlink(missing_ok=True)

    # Ensure SAN includes db.<region>.<zone> so clients can connect via VIP DNS name
    run(
        "cockroach cert create-node "
        f"{node['name']} "
        f"db.{node['region']}.{dns_zone} "
        "localhost "
        f"--certs-dir={certs_dir} "
        f"--ca-key={ca_key}"
    )


def generate_pgb_server_cert(region: str, dns_zone: str, certs_dir: Path, ca_key: Path, client_user: str) -> Tuple[Path, Path]:
    """
    Create a server certificate for PgBouncer endpoint pgb.<region>.<zone>.
    Rename it to match start-pgbouncer.sh expectations:
      /etc/pgbouncer/certs/server.<client_user>.crt|key
    """
    (certs_dir / "node.crt").unlink(missing_ok=True)
    (certs_dir / "node.key").unlink(missing_ok=True)

    run(
        "cockroach cert create-node "
        f"pgb.{region}.{dns_zone} "
        "localhost "
        f"--certs-dir={certs_dir} "
        f"--ca-key={ca_key}"
    )

    server_crt = certs_dir / f"server.{client_user}.crt"
    server_key = certs_dir / f"server.{client_user}.key"
    server_crt.unlink(missing_ok=True)
    server_key.unlink(missing_ok=True)

    (certs_dir / "node.crt").replace(server_crt)
    (certs_dir / "node.key").replace(server_key)
    return server_crt, server_key


# ----------------------------
# Remote installs
# ----------------------------

def install_crdb_certs(node: Dict[str, Any], ssh_user: str, ssh_key: str, certs_dir: Path) -> None:
    host = node["public_dns"]
    # Push CA and node certs
    run(f"scp -i {ssh_key} {certs_dir}/ca.crt {ssh_user}@{host}:/tmp/ca.crt")
    run(f"scp -i {ssh_key} {certs_dir}/node.crt {ssh_user}@{host}:/tmp/node.crt")
    run(f"scp -i {ssh_key} {certs_dir}/node.key {ssh_user}@{host}:/tmp/node.key")
    run(f"""
ssh -i {ssh_key} {ssh_user}@{host} <<'EOF'
sudo mkdir -p /var/lib/cockroach/certs
sudo mv /tmp/ca.crt /tmp/node.crt /tmp/node.key /var/lib/cockroach/certs
sudo chown -R cockroach:cockroach /var/lib/cockroach
sudo chmod 0644 /var/lib/cockroach/certs/*.crt
sudo chmod 0600 /var/lib/cockroach/certs/node.key
EOF
""")


# ----------------------------
# HAProxy rendering + deploy
# ----------------------------

def render_haproxy_cfg(pgbouncer_ips: List[str], backend_ips: List[str], pgb_port: int = 5432, db_port: int = 26257) -> str:
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
        lines.append(f"  server pgb{i} {ip}:{pgb_port} check")

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

    lines.append("")
    return "\n".join(lines)


def push_haproxy_cfg(host: str, ssh_user: str, ssh_key: str, cfg: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        local = Path(td) / "haproxy.cfg"
        local.write_text(cfg)
        run(f"scp -i {ssh_key} {local} {ssh_user}@{host}:/tmp/haproxy.cfg")
        run(f"""
ssh -i {ssh_key} {ssh_user}@{host} <<'EOF'
sudo mv /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
EOF
""")


# ----------------------------
# Cockroach start / init
# ----------------------------

def install_and_start_crdb_service(nodes: List[Dict[str, Any]], ssh_user: str, ssh_key: str) -> None:
    total_nodes = len(nodes)
    join = ",".join(f"{n['name']}:26257" for n in nodes)

    for node in nodes:
        host = node["public_dns"]
        name = node["name"]
        region = node.get("region", "unknown")
        az = node.get("az", "")

        if total_nodes == 1:
            exec_start = (
                "/usr/local/bin/cockroach start-single-node "
                "--certs-dir=/var/lib/cockroach/certs "
                "--store=/mnt/cockroach-data "
                "--listen-addr=0.0.0.0:26257 "
                f"--advertise-addr={name}:26257 "
                "--http-addr=0.0.0.0:8080 "
                f"--locality=region={region},zone={az}"
            )
        else:
            exec_start = (
                "/usr/local/bin/cockroach start "
                "--certs-dir=/var/lib/cockroach/certs "
                "--store=/mnt/cockroach-data "
                "--listen-addr=0.0.0.0:26257 "
                f"--advertise-addr={name}:26257 "
                "--http-addr=0.0.0.0:8080 "
                f"--join={join} "
                f"--locality=region={region},zone={az}"
            )

        run(f"""
ssh -i {ssh_key} {ssh_user}@{host} <<'EOF'
sudo tee /etc/systemd/system/cockroach.service > /dev/null <<SERVICE
[Unit]
Description=CockroachDB
After=network-online.target
Wants=network-online.target

[Service]
User=cockroach
ExecStart={exec_start}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable cockroach
sudo systemctl restart cockroach
EOF
""")


def wait_for_crdb(nodes: List[Dict[str, Any]], ssh_user: str, ssh_key: str, timeout: int = 300) -> None:
    deadline = time.time() + timeout
    print("⏳ Waiting for Cockroach nodes to become ready...")

    while time.time() < deadline:
        seed = nodes[0]
        host = seed["public_dns"]
        try:
            run(f"""
ssh -i {ssh_key} {ssh_user}@{host} <<'EOF'
cockroach node status \
  --certs-dir=/var/lib/cockroach/certs \
  --host=localhost:26257
EOF
""", check=False)

            print("✅ Nodes are responding")
            return

        except Exception:
            pass

        time.sleep(5)

    raise RuntimeError("Timed out waiting for Cockroach nodes")


def init_cluster(seed_node: Dict[str, Any], clients_dir: Path) -> None:
    seed = f"{seed_node['name']}:26257"
    run(f"cockroach init --certs-dir={clients_dir} --host={seed}")


# ----------------------------
# Validation
# ----------------------------

def validate_region(region: str, dns_zone: str, certs_dir: Path, pgb_client_user: str) -> None:
    # Direct Cockroach (VIP DNS)
    db_host = f"db.{region}.{dns_zone}:26257"
    run(f"cockroach sql --certs-dir={certs_dir} --host={db_host} -e 'SELECT 1;'")

    # PgBouncer (VIP DNS) with client cert auth
    # Requires client.<pgb_client_user>.crt/key created locally
    pgb_host = f"pgb.{region}.{dns_zone}"
    run(
        "psql "
        f"\"host={pgb_host} port=5432 dbname=defaultdb sslmode=verify-full "
        f"sslrootcert={certs_dir/'ca.crt'} "
        f"sslcert={certs_dir/f'client.{pgb_client_user}.crt'} "
        f"sslkey={certs_dir/f'client.{pgb_client_user}.key'}\" "
        "-c 'SELECT 1;'"
    )


# ----------------------------
# Main
# ----------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform-dir", required=True)
    parser.add_argument("--tfvars-file", required=True)
    parser.add_argument("--certs-dir", required=True)
    parser.add_argument("--ca-key", default="./my-safe-directory/ca.key")
    parser.add_argument("--ssh-user", default="debian")
    parser.add_argument("--ssh-key", required=True)
    parser.add_argument("--dns-zone", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--skip-init", action="store_true")
    parser.add_argument("--skip-haproxy", action="store_true")
    parser.add_argument("--skip-pgb-certs", action="store_true")
    parser.add_argument("--pgb-client-user", default="postgres")
    parser.add_argument("--pgb-server-user", default="root")
    args = parser.parse_args()

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

    # Flatten proxies (dcp nodes)
    proxies: List[Dict[str, Any]] = []
    for region, region_proxies in dcp_endpoints_by_region.items():
        for p in region_proxies:
            p["region"] = region
            proxies.append(p)

    # Group by region
    crdb_by_region: Dict[str, List[Dict[str, Any]]] = {}
    for n in nodes:
        crdb_by_region.setdefault(n["region"], []).append(n)

    dcp_by_region: Dict[str, List[Dict[str, Any]]] = {}
    for p in proxies:
        dcp_by_region.setdefault(p["region"], []).append(p)

    certs_dir = Path(args.certs_dir).expanduser().resolve()
    ca_key = Path(args.ca_key).expanduser().resolve()

    # CA + client certs
    # root: for CRDB admin and for PgBouncer->CRDB client cert (client.root.*)
    # postgres: for app clients connecting to PgBouncer in cert mode
    ensure_ca_and_clients(certs_dir, ca_key, create_client_users=["root", args.pgb_client_user])

    # Cockroach node certs + install
    for node in nodes:
        generate_crdb_node_cert(node, args.dns_zone, certs_dir, ca_key)
        install_crdb_certs(node, args.ssh_user, args.ssh_key, certs_dir)

    install_and_start_crdb_service(nodes, args.ssh_user, args.ssh_key)
    wait_for_crdb(nodes, args.ssh_user, args.ssh_key)

    if not args.skip_init and len(nodes) > 1:
        init_cluster(nodes[0], certs_dir)

    # PgBouncer certs install on every DCP node (per region)
    if not args.skip_pgb_certs:
        for region, region_proxies in dcp_by_region.items():
            # Generate server cert for pgb.<region>.<zone> and push to all proxies in that region
            # NOTE: generate_pgb_server_cert uses ca_key; we call it per region and then scp the generated files.
            # We do the generation once, then reuse the file copies.
            generate_pgb_server_cert(region, args.dns_zone, certs_dir, ca_key, args.pgb_client_user)

            for p in region_proxies:
                host = p["public_dns"] or p.get("public_ip") or p["private_ip"]

                # Copy: ca.crt, server.<pgb_client_user>.*, client.<pgb_server_user>.*
                run(f"scp -i {args.ssh_key} {certs_dir/'ca.crt'} {args.ssh_user}@{host}:/tmp/ca.crt")
                run(f"scp -i {args.ssh_key} {certs_dir/f'server.{args.pgb_client_user}.crt'} {args.ssh_user}@{host}:/tmp/server.{args.pgb_client_user}.crt")
                run(f"scp -i {args.ssh_key} {certs_dir/f'server.{args.pgb_client_user}.key'} {args.ssh_user}@{host}:/tmp/server.{args.pgb_client_user}.key")
                run(f"scp -i {args.ssh_key} {certs_dir/f'client.{args.pgb_server_user}.crt'} {args.ssh_user}@{host}:/tmp/client.{args.pgb_server_user}.crt")
                run(f"scp -i {args.ssh_key} {certs_dir/f'client.{args.pgb_server_user}.key'} {args.ssh_user}@{host}:/tmp/client.{args.pgb_server_user}.key")

                run(f"""
ssh -i {args.ssh_key} {args.ssh_user}@{host} <<'EOF'
sudo mkdir -p /etc/pgbouncer/certs
sudo mv /tmp/ca.crt /etc/pgbouncer/certs/ca.crt
sudo mv /tmp/server.*.crt /etc/pgbouncer/certs/
sudo mv /tmp/server.*.key /etc/pgbouncer/certs/
sudo mv /tmp/client.*.crt /etc/pgbouncer/certs/
sudo mv /tmp/client.*.key /etc/pgbouncer/certs/
sudo chown -R postgres:postgres /etc/pgbouncer
sudo chmod 0644 /etc/pgbouncer/certs/*.crt
sudo chmod 0600 /etc/pgbouncer/certs/*.key
sudo systemctl restart pgbouncer-runner || sudo systemctl restart pgbouncer-launcher || true
EOF
""")

    # HAProxy config per region (PgBouncer pool = all DCP nodes in region)
    if not args.skip_haproxy:
        for region, region_proxies in dcp_by_region.items():
            pgbouncer_ips = [p["private_ip"] for p in region_proxies]
            backend_ips = [n["private_ip"] for n in crdb_by_region.get(region, [])]
            if not backend_ips:
                raise RuntimeError(f"No Cockroach nodes found for region {region}")

            cfg = render_haproxy_cfg(pgbouncer_ips, backend_ips)

            for p in region_proxies:
                host = p["public_dns"] or p.get("public_ip") or p["private_ip"]
                push_haproxy_cfg(host, args.ssh_user, args.ssh_key, cfg)

    # Validate endpoints (local machine -> DNS)
    for region in sorted(dcp_by_region.keys()):
        validate_region(region, args.dns_zone, certs_dir, args.pgb_client_user)

    print("\n✅ Bootstrap complete (Cockroach + DCP + HAProxy configured)")
