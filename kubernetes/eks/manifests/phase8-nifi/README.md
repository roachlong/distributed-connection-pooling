# Phase 8: Apache NiFi Data Flow Platform

Deploys **Apache NiFi 2.x** as the data flow and ETL orchestration layer on EKS, providing a scalable, resilient, multi-node NiFi cluster with NiFi Registry, ZooKeeper coordination, Kafka messaging, and full TLS/mTLS security — integrated with CockroachDB via JDBC.

## Why NiFi 2.x on Kubernetes

NiFi has historically been deployed on EC2 due to its large JVM heap requirements, sensitive I/O performance characteristics, and complex multi-node clustering model. NiFi 2.x changed the picture:

- **Stateless NiFi mode**: NiFi 2.0 introduced a true stateless execution engine that runs flows without a local repository, decoupling processing state from the node. This makes pods genuinely ephemeral and restartable without data loss, which was not feasible with 1.x.
- **Externalized configuration**: All sensitive properties, TLS credentials, and cluster parameters can be injected via environment variables and mounted volumes — aligning directly with Kubernetes Secrets and ConfigMaps. In 1.x, many settings required in-place file manipulation on running nodes.
- **Container-first distribution**: The Apache NiFi project now publishes official Docker images (`apache/nifi:2.x`) with entrypoint scripts that honor environment variable configuration. Certificate paths, ZooKeeper connect strings, heap sizes, and repository directories are all environment-driven.
- **Improved cluster election**: NiFi 2.x tightened cluster flow election behavior to be more tolerant of pod restart delays, reducing the risk of split-brain during rolling updates — a major pain point in Kubernetes 1.x deployments.
- **Java 21 requirement enforced cleanly**: NiFi 2.x requires Java 21 and is built against it from the start. The official container image ships with a correctly configured JVM, eliminating the manual JDK installation and heap tuning steps needed on bare metal.
- **Registry-first flow management**: NiFi 2.x deepened the Registry integration, making versioned flow deployment the canonical way to distribute flows across a cluster. This maps naturally to GitOps: flows live in Git, Registry syncs from Git, NiFi nodes load from Registry.

The net result: a NiFi 2.x cluster on EKS with StatefulSets, dedicated node groups, and properly provisioned EBS volumes delivers equivalent stability and performance to an EC2 deployment, with the operational benefits of a unified Kubernetes control plane.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  EKS NiFi Node Group (dedicated, r6i.4xlarge, tainted)                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  ZooKeeper StatefulSet (3 replicas, namespace: nifi)                │   │
│  │  zookeeper-0 / zookeeper-1 / zookeeper-2                           │   │
│  │  Ports: 2181 (client), 2888:3888 (peer)                            │   │
│  │  Storage: 10Gi gp3 PVC per pod                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │ ZK connect string                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Kafka StatefulSet (3 replicas, namespace: nifi)                    │   │
│  │  kafka-0 / kafka-1 / kafka-2                                       │   │
│  │  Ports: 9092 (broker)                                              │   │
│  │  Storage: 100Gi gp3 PVC per pod (log.dirs)                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  NiFi StatefulSet (3 replicas, namespace: nifi)                     │   │
│  │  nifi-0 / nifi-1 / nifi-2                                         │   │
│  │  Ports: 9443 (HTTPS UI), 10443 (S2S), 11443 (cluster protocol)    │   │
│  │                                                                     │   │
│  │  PVCs per pod (6 volumes):                                         │   │
│  │    flowfile-repo   20Gi  gp3                                       │   │
│  │    content-repo-1  50Gi  gp3 (16,000 IOPS)                        │   │
│  │    content-repo-2  50Gi  gp3 (16,000 IOPS)                        │   │
│  │    content-repo-3  50Gi  gp3 (16,000 IOPS)                        │   │
│  │    prov-repo-1     50Gi  gp3 (16,000 IOPS)                        │   │
│  │    prov-repo-2     50Gi  gp3 (16,000 IOPS)                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  NiFi Registry Deployment (1 replica, namespace: nifi)              │   │
│  │  Ports: 19443 (HTTPS)                                              │   │
│  │  Storage: 20Gi gp3 PVC (flow database + git clone)                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
          │ JDBC (26257)                          │ mTLS (Istio passthrough)
          ▼                                        ▼
┌──────────────────────┐             ┌──────────────────────────────┐
│  PgBouncer Batch     │             │  Istio Ingress Gateway       │
│  Port 5433           │             │  (NiFi UI passthrough)       │
│  (BYPASSRLS for ETL) │             └──────────────────────────────┘
└──────────────────────┘
          │
          ▼
┌──────────────────────┐
│  CockroachDB Cluster │
│  (3 nodes, port 26257│
└──────────────────────┘
```

## Component Design

### Namespace

All NiFi components run in a dedicated `nifi` namespace, separate from `cockroachdb`. Istio sidecar injection is enabled on the namespace but NiFi's own cluster protocol ports (11443) and S2S ports (10443) are configured as Istio passthrough — NiFi handles its own mTLS on those ports. The NiFi UI (9443) is exposed through the Istio ingress gateway.

### ZooKeeper (StatefulSet, 3 replicas)

NiFi 2.x uses ZooKeeper for cluster state coordination. ZooKeeper runs as a separate 3-node StatefulSet to give it independent scaling and failure isolation from the NiFi nodes. This matches the decoupled architecture recommended for production K8s deployments.

```yaml
# Key ZooKeeper configuration
tickTime: 2000
initLimit: 10
syncLimit: 5
clientPort: 2181
dataDir: /data
dataLogDir: /datalog
```

**Headless service** (`zookeeper-headless`) provides DNS entries for each pod: `zookeeper-0.zookeeper-headless.nifi.svc.cluster.local`, etc.

### Kafka (StatefulSet, 3 replicas)

Kafka runs in ZooKeeper mode (matching the existing EC2 setup). Each broker gets its own PVC for log storage. Advertised listeners use the pod's stable DNS name from the headless service.

> **Note**: Consider migrating to KRaft mode (Kafka without ZooKeeper) or Amazon MSK in a future phase to reduce operational footprint.

### NiFi Cluster (StatefulSet, 3 replicas)

The NiFi StatefulSet provides:
- **Stable network identity**: Pod names `nifi-0`, `nifi-1`, `nifi-2` with DNS `nifi-N.nifi-headless.nifi.svc.cluster.local`
- **Ordered startup**: `podManagementPolicy: OrderedReady` ensures ZooKeeper is established before NiFi pods start (via init containers)
- **6 PVCs per pod**: Separate volumes for each repository type, matching the multi-mount I/O design from the EC2 setup

**NiFi properties translated from EC2 setup:**

| EC2 setting | K8s equivalent |
|---|---|
| `nifi.cluster.node.address = hostname` | Pod DNS name from headless service |
| `nifi.zookeeper.connect.string` | `zookeeper-0.zookeeper-headless...:2181,...` |
| `/opt/nifi/certs/keystore.p12` | `tls.crt` / `tls.key` / `ca.crt` mounted from Secret (PEM) |
| `SENSITIVE_KEY` env var | Kubernetes Secret → env injection |
| `/mnt/flowfile-repo` | PVC mounted at same path |
| `LimitNOFILE=65535` | Pod `securityContext.sysctls` + node DaemonSet |
| UFW peer rules | NetworkPolicy resources |
| systemd `Restart=on-failure` | Pod `restartPolicy: Always` (StatefulSet default) |

### NiFi Registry (Deployment, 1 replica)

Registry runs as a standard Deployment (not StatefulSet) with a single PVC for flow storage. Git integration is preserved: the Registry is configured with a GitHub flow provider, using a Secret for the PAT token. This maintains the same GitOps-style flow versioning from the EC2 setup.

## Certificate Management

Certificates are issued by **Vault PKI via cert-manager** — the same `vault-issuer` ClusterIssuer used for CockroachDB and PgBouncer certs in Phases 4 and 5. This keeps NiFi on the same trust chain as the rest of the stack and is consistent with the Phase 2 Vault PKI setup.

cert-manager watches `Certificate` resources, calls the Vault PKI secrets engine via the `vault-issuer` ClusterIssuer, and stores the result as a standard Kubernetes Secret:

```
Vault PKI (Phase 2)
  └── vault-issuer ClusterIssuer (cert-manager)
        └── Certificate resource (nifi-node-0)
              ├── dnsNames: [nifi-0.nifi-headless.nifi.svc.cluster.local, nifi-0, localhost]
              └── Output: Secret nifi-tls-nifi-0
                    ├── tls.crt  (node certificate, PEM)
                    ├── tls.key  (private key, PEM)
                    └── ca.crt   (CA bundle, PEM)
```

NiFi 2.x supports PEM keystores natively (`nifi.security.keystoreType=PEM`), so the cert-manager-issued PEM files are mounted directly into the NiFi pod — no PKCS12 conversion needed, and no keystore password required.

```properties
# nifi.properties (rendered from ConfigMap)
nifi.security.keystore=/opt/nifi/certs/tls.crt
nifi.security.keystoreType=PEM
nifi.security.keystore.key=/opt/nifi/certs/tls.key
nifi.security.truststore=/opt/nifi/certs/ca.crt
nifi.security.truststoreType=PEM
```

The same CA that signs CockroachDB and PgBouncer certs signs the NiFi node certs, giving NiFi mutual TLS with the rest of the stack through the shared Vault root CA.

**Certificate SANs per node:**
- `nifi-N.nifi-headless.nifi.svc.cluster.local` (stable pod DNS)
- `nifi-N` (short name)
- `localhost` (local health checks)

The cert DN follows the same `CN=nifi-N, OU=NIFI` pattern as the EC2 setup, preserving the authorizers.xml identity model.

## Sensitive Properties Key

The NiFi sensitive properties key (16+ character string that encrypts credentials stored in NiFi's config) and the GitHub PAT for Registry are stored in **Vault KV secrets engine** and injected as Kubernetes Secrets by `setup.sh` — consistent with how all other phases in this stack manage sensitive values.

```bash
# setup.sh stores values in Vault KV (run once during initial setup)
vault kv put secret/nifi/config \
  sensitive_key="$(openssl rand -base64 24)" \
  git_token="${GIT_TOKEN}"

# setup.sh then creates the K8s Secret from Vault KV
kubectl create secret generic nifi-sensitive-props \
  --namespace nifi \
  --from-literal=SENSITIVE_KEY="$(vault kv get -field=sensitive_key secret/nifi/config)"

kubectl create secret generic nifi-git-token \
  --namespace nifi \
  --from-literal=GIT_TOKEN="$(vault kv get -field=git_token secret/nifi/config)"
```

The `SENSITIVE_KEY` is injected into NiFi pods as an environment variable and referenced in `nifi.properties` via `${SENSITIVE_KEY}`. Since NiFi 2.x uses PEM certs (no keystore password required), there are no additional password secrets needed.

## Storage Classes

A dedicated StorageClass is required for NiFi's high-IOPS volumes:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nifi-high-iops
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "16000"
  throughput: "1000"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```

`WaitForFirstConsumer` ensures each PVC lands in the same AZ as its pod — critical for EBS volumes which are AZ-local.

`reclaimPolicy: Retain` prevents accidental data loss on pod deletion.

## Node Group & Scheduling

NiFi requires dedicated worker nodes. A separate EKS managed node group is added to the existing cluster:

```yaml
# eksctl node group addition
managedNodeGroups:
  - name: nifi-workers
    instanceType: r6i.4xlarge   # 16 vCPU, 128GB RAM
    minSize: 3
    maxSize: 6
    desiredCapacity: 3
    availabilityZones: [us-east-2a, us-east-2b, us-east-2c]
    taints:
      - key: dedicated
        value: nifi
        effect: NoSchedule
    labels:
      role: nifi
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

NiFi pods carry the matching toleration and a `nodeAffinity` rule pinning them to `role=nifi` nodes. ZooKeeper and Kafka pods also run on these nodes (same taint/toleration) to keep NiFi traffic intra-node-group.

**Kernel tuning DaemonSet** applies the same Linux sysctl values from the EC2 setup to the NiFi node group:

```yaml
vm.swappiness = 1
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
net.core.somaxconn = 4096
fs.file-max = 2097152
```

## Network Policies

UFW rules from the EC2 setup are replaced with Kubernetes NetworkPolicies:

| EC2 UFW rule | NetworkPolicy equivalent |
|---|---|
| Allow ZK client 2181 from peers | `nifi` pods → `zookeeper` pods, port 2181 |
| Allow ZK peer 2888:3888 | `zookeeper` pods → `zookeeper` pods, ports 2888/3888 |
| Allow Kafka 9092 from peers | `nifi` pods → `kafka` pods, port 9092; `kafka` inter-broker |
| Allow NiFi cluster 11443 | `nifi` pods → `nifi` pods, port 11443 |
| Allow NiFi S2S 10443 | external → `nifi` pods, port 10443 (via ingress) |
| Allow NiFi UI 9443 | Istio ingress → `nifi` pods, port 9443 |
| Allow load balance 6342 | `nifi` pods → `nifi` pods, port 6342 |
| Allow dist. map cache 4557 | `nifi` pods → `nifi` pods, port 4557 |
| Allow JDBC to CRDB 26257 | `nifi` pods → `cockroachdb` namespace, port 26257 |

Default deny-all ingress policy on `nifi` namespace with explicit allow rules per the above.

## Istio Integration

NiFi sits behind the Istio mesh deployed in Phase 6, with one important configuration: NiFi's own TLS on cluster protocol and S2S ports must not be intercepted by the Envoy sidecar.

```yaml
# DestinationRule: passthrough for NiFi TLS ports
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: nifi-tls-passthrough
  namespace: nifi
spec:
  host: "*.nifi-headless.nifi.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE   # NiFi handles its own TLS; sidecar passes through
```

The NiFi UI (port 9443) is exposed via an Istio Gateway with TLS passthrough to the NiFi pod (NiFi terminates HTTPS with its own cert, not Istio's). Access requires the admin client certificate issued during setup, matching the EC2 secure-mode behavior.

## Init Containers

Each NiFi pod uses init containers to enforce startup ordering (replacing the systemd dependency chain):

1. **`wait-for-zookeeper`**: Polls ZooKeeper client port (2181) on all 3 ZK pods until quorum is established
2. **`wait-for-kafka`**: Polls Kafka port (9092) on all 3 brokers
3. **`cert-preflight`**: Verifies the TLS Secret is mounted and the keystore is readable before NiFi starts

```yaml
initContainers:
  - name: wait-for-zookeeper
    image: busybox:1.36
    command: ['sh', '-c', |
      for i in 0 1 2; do
        until nc -z zookeeper-$i.zookeeper-headless.nifi.svc.cluster.local 2181; do
          echo "Waiting for zookeeper-$i..."; sleep 5;
        done;
      done]
```

## CockroachDB JDBC Integration

NiFi connects to CockroachDB via the PgBouncer batch pool (port 5433, BYPASSRLS) for ETL operations. The PostgreSQL JDBC driver is included in the NiFi container image:

```dockerfile
FROM apache/nifi:2.5.0
COPY postgresql-42.7.7.jar /opt/nifi/nifi-current/lib/
```

The JDBC connection string in NiFi controller services:
```
jdbc:postgresql://pgbouncer-batch.cockroachdb.svc.cluster.local:5433/production?sslmode=require
```

Username `pgb_batch_user` credentials are stored as a NiFi sensitive property (encrypted with `SENSITIVE_KEY`).

For DDL-heavy flows that bypass PgBouncer (matching the Flyway pattern), flows can connect directly to `cockroachdb-east-public.cockroachdb.svc.cluster.local:26257` using the `flyway_svc` client certificate.

## Scaling

Horizontal scaling is a `kubectl scale` command:

```bash
# Scale NiFi cluster from 3 to 5 nodes
kubectl scale statefulset nifi --replicas=5 -n nifi

# Scale down (graceful, ordered)
kubectl scale statefulset nifi --replicas=3 -n nifi
```

**Scale-up procedure:**
1. New pod starts, joins ZooKeeper
2. NiFi cluster election detects new node
3. Primary node distributes flow to new node
4. Load balancer begins routing to new node

**Scale-down procedure:**
1. Pod is gracefully terminated (SIGTERM → `nifi.sh stop`)
2. In-flight FlowFiles are checkpointed to persistent storage
3. Cluster re-elects and redistributes load
4. PVC is retained (reclaimPolicy: Retain) for recovery if needed

The ZooKeeper quorum size is fixed at 3 for stability. Only NiFi nodes and Kafka brokers scale independently.

## NiFi Registry Git Integration

Registry is configured with the GitHub flow provider, preserving the existing Git-backed versioning workflow:

```yaml
# nifi-registry.properties (rendered from ConfigMap)
nifi.registry.flow.provider.git.remote.to.push=origin
nifi.registry.flow.provider.git.remote.access-token=${GIT_TOKEN}
nifi.registry.flow.provider.git.flow.storage.directory=/opt/nifi-registry/flow-storage
nifi.registry.flow.provider.git.remote.url=https://github.com/org/nifi-flows.git
```

`GIT_TOKEN` is stored in Vault KV and injected as a Kubernetes Secret by `setup.sh`, same pattern as the sensitive properties key above.

## Container Image

A custom NiFi image layers additional dependencies on top of the official Apache image:

```dockerfile
FROM apache/nifi:2.5.0

# PostgreSQL JDBC driver for CockroachDB connectivity
COPY postgresql-42.7.7.jar /opt/nifi/nifi-current/lib/

# NiFi Toolkit (for cert generation / cluster operations)
ARG NIFI_TOOLKIT_VERSION=2.5.0
RUN curl -fsSL https://downloads.apache.org/nifi/${NIFI_TOOLKIT_VERSION}/nifi-toolkit-${NIFI_TOOLKIT_VERSION}-bin.zip \
    -o /tmp/toolkit.zip && unzip /tmp/toolkit.zip -d /opt/ && rm /tmp/toolkit.zip
```

Image is pushed to ECR and referenced in the StatefulSet spec.

## What Gets Deployed

| Resource | Kind | Count | Notes |
|---|---|---|---|
| `zookeeper` | StatefulSet | 3 pods | ZK quorum, 10Gi PVC each |
| `kafka` | StatefulSet | 3 pods | Brokers, 100Gi PVC each |
| `nifi` | StatefulSet | 3 pods | 6 PVCs per pod (270Gi total) |
| `nifi-registry` | Deployment | 1 pod | 20Gi PVC |
| `nifi-headless` | Service (headless) | — | Pod DNS for cluster |
| `nifi-ui` | Service (ClusterIP) | — | Port 9443 → Istio ingress |
| `zookeeper-headless` | Service (headless) | — | ZK peer communication |
| `kafka-headless` | Service (headless) | — | Kafka inter-broker |
| `nifi-registry` | Service (ClusterIP) | — | Port 19443 |
| `nifi-sensitive-props` | Secret (from Vault KV) | — | SENSITIVE_KEY |
| `nifi-git-token` | Secret (from Vault KV) | — | GitHub PAT for Registry |
| `nifi-tls-nifi-N` | Certificate (Vault PKI via cert-manager) | 3 | Per-pod TLS certs, PEM format |
| `nifi-registry-tls` | Certificate (Vault PKI via cert-manager) | 1 | Registry TLS cert, PEM format |
| `nifi-kernel-tuning` | DaemonSet | per node | sysctl tuning on nifi nodes |
| NetworkPolicy | NetworkPolicy | ~8 | Deny-all + explicit allows |
| `nifi-high-iops` | StorageClass | — | gp3 16,000 IOPS |
| `nifi-workers` | Node Group | 3–6 nodes | r6i.4xlarge, dedicated + tainted |

## Prerequisites

- **Phase 1 complete**: EKS cluster deployed (nifi node group added here)
- **Phase 2 complete**: Vault PKI + cert-manager with `vault-issuer` ClusterIssuer operational
- **Phase 3 complete**: CockroachDB Operator installed
- **Phase 4 complete**: CockroachDB cluster running
- **Phase 5 complete**: PgBouncer batch pool available (port 5433)
- **Phase 6 complete**: Istio service mesh deployed
- **Phase 7 complete**: Flyway migrations applied (production schema exists)
- **Vault KV secrets**: `secret/nifi/config` populated with `sensitive_key` and `git_token`
- **ECR repository**: For custom NiFi container image
- **GitHub repository**: For NiFi Registry flow storage (or configure local Git)

## Deployment

### Step 1: Add NiFi Node Group

```bash
cd kubernetes/eks/manifests/phase8-nifi

# Add dedicated NiFi node group to existing EKS cluster
eksctl create nodegroup \
  --cluster ${EKS_CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --name nifi-workers \
  --node-type r6i.4xlarge \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 6 \
  --node-labels role=nifi \
  --node-taints dedicated=nifi:NoSchedule \
  --asg-access
```

### Step 2: Apply Kernel Tuning DaemonSet

```bash
kubectl apply -f daemonsets/nifi-kernel-tuning.yaml
kubectl rollout status daemonset/nifi-kernel-tuning -n nifi
```

### Step 3: Store Secrets in Vault KV

```bash
# Port-forward to Vault (or exec into vault-0 pod)
kubectl port-forward -n vault svc/vault-ui 8200:8200 &
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(kubectl get secret -n vault vault-keys -o jsonpath='{.data.root_token}' | base64 -d)

# Store NiFi sensitive values in Vault KV
vault kv put secret/nifi/config \
  sensitive_key="$(openssl rand -base64 24)" \
  git_token="${GIT_TOKEN}"

# Verify
vault kv get secret/nifi/config
```

`setup.sh` reads these values from Vault KV and creates the Kubernetes Secrets in the `nifi` namespace — the same pattern used in Phases 4 and 5 for CockroachDB and PgBouncer credentials.

### Step 4: Run Setup Script

```bash
chmod +x setup.sh
./setup.sh
```

The setup script will:
1. Create `nifi` namespace with Istio sidecar injection enabled
2. Apply StorageClass `nifi-high-iops`
3. Pull secrets from Vault KV and create Kubernetes Secrets (`nifi-sensitive-props`, `nifi-git-token`)
4. Apply cert-manager `Certificate` resources against `vault-issuer` ClusterIssuer for all NiFi nodes and Registry
5. Deploy ZooKeeper StatefulSet, wait for quorum
6. Deploy Kafka StatefulSet, wait for all brokers ready
7. Deploy NiFi StatefulSet (3 nodes), wait for cluster formation
8. Deploy NiFi Registry, configure Git provider
9. Apply NetworkPolicies
10. Apply Istio DestinationRules and Gateway for NiFi UI
11. Run cluster health check (all nodes CONNECTED in ZooKeeper)

### Step 5: Verify Cluster Formation

```bash
# Check all pods are running
kubectl get pods -n nifi

# Expected output:
# NAME                    READY   STATUS    RESTARTS   AGE
# zookeeper-0             1/1     Running   0          5m
# zookeeper-1             1/1     Running   0          4m
# zookeeper-2             1/1     Running   0          4m
# kafka-0                 1/1     Running   0          4m
# kafka-1                 1/1     Running   0          3m
# kafka-2                 1/1     Running   0          3m
# nifi-0                  2/2     Running   0          3m  (2/2 = NiFi + Istio sidecar)
# nifi-1                  2/2     Running   0          2m
# nifi-2                  2/2     Running   0          2m
# nifi-registry-<hash>    2/2     Running   0          2m

# Check NiFi cluster status via ZooKeeper
kubectl exec -n nifi zookeeper-0 -- \
  /opt/zookeeper/bin/zkCli.sh -server localhost:2181 \
  ls /nifi/cluster/nodes/connected
# Expected: [nifi-0..., nifi-1..., nifi-2...]

# Check NiFi logs for cluster formation
kubectl logs -n nifi nifi-0 -c nifi --tail=50 | grep -i "cluster\|connected\|elected"
```

### Step 6: Access NiFi UI

```bash
# Port-forward for local access (development)
kubectl port-forward -n nifi svc/nifi-ui 9443:9443

# Access: https://localhost:9443/nifi
# Auth: Client certificate (admin cert issued during setup)
```

For production access, the Istio ingress gateway exposes the NiFi UI with TLS passthrough to the configured domain.

## Validation

```bash
# Verify ZooKeeper quorum (all 3 nodes: leader + 2 followers)
for i in 0 1 2; do
  kubectl exec -n nifi zookeeper-$i -- \
    /opt/zookeeper/bin/zkServer.sh status 2>/dev/null | grep -E "leader|follower"
done

# Verify Kafka brokers registered in ZooKeeper
kubectl exec -n nifi zookeeper-0 -- \
  /opt/zookeeper/bin/zkCli.sh -server localhost:2181 \
  ls /brokers/ids
# Expected: [0, 1, 2]

# Verify NiFi cluster flow election completed
kubectl exec -n nifi nifi-0 -- \
  curl -sk https://localhost:9443/nifi-api/cluster \
  --cert /opt/nifi/nifi-current/conf/certs/tls.crt \
  --key /opt/nifi/nifi-current/conf/certs/tls.key | \
  jq '.cluster.nodes[] | {address: .address, status: .status}'
# Expected: all nodes "CONNECTED"

# Verify CockroachDB JDBC connectivity from NiFi
kubectl exec -n nifi nifi-0 -- \
  curl -sk -X POST https://localhost:9443/nifi-api/controller/config \
  # (test via NiFi UI: create a DBCPConnectionPool controller service,
  #  set JDBC URL to pgbouncer-batch:5433, test connection)

# Verify Registry sync
kubectl exec -n nifi nifi-registry-<pod> -n nifi -- \
  curl -sk https://localhost:19443/nifi-registry/api/buckets | jq '.[].name'
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 8
```

This removes:
- NiFi, ZooKeeper, Kafka StatefulSets and all pods
- All PVCs (WARNING: destroys flowfile, content, and provenance data)
- NiFi Registry Deployment and PVC
- All Secrets, ConfigMaps, NetworkPolicies
- Istio Gateway and DestinationRules for NiFi
- Vault PKI Certificates (via cert-manager) for NiFi nodes and Registry
- NiFi namespace

**Does NOT remove:**
- The `nifi-workers` node group (must be deleted separately via eksctl)
- Vault KV secret entries (`secret/nifi/config`)
- GitHub flow repository content
- CockroachDB data written by NiFi flows

```bash
# Remove NiFi node group separately
eksctl delete nodegroup \
  --cluster ${EKS_CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --name nifi-workers
```

## Next Steps

### Phase 9: Enterprise Features

Enable CockroachDB Enterprise features:
- S3 backups with IRSA (automated full + incremental)
- Encryption-at-rest with customer-managed keys
- Changefeeds for NiFi flows (real-time CockroachDB → NiFi data streaming)

See [manifests/phase9-enterprise/README.md](../phase9-enterprise/README.md)

## References

**Apache NiFi:**
- [NiFi 2.x Docker Image](https://hub.docker.com/r/apache/nifi)
- [NiFi Administration Guide](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html)
- [NiFi Clustering](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#clustering)
- [NiFi on Kubernetes (Community)](https://nifi.apache.org/docs/nifi-docs/html/kubernetes.html)

**NiFi Registry:**
- [NiFi Registry Administration](https://nifi.apache.org/docs/nifi-registry-docs/html/administration-guide.html)
- [Git Flow Persistence Provider](https://nifi.apache.org/docs/nifi-registry-docs/html/administration-guide.html#git-flow-persistence-provider)

**Related Architecture:**
- [ARCHITECTURE.md](../../ARCHITECTURE.md) - EKS stack overview
- [Phase 2 README](../phase2-certificates/README.md) - Vault PKI + cert-manager (`vault-issuer` ClusterIssuer)
- [Phase 5 README](../phase5-pgbouncer/README.md) - PgBouncer batch pool (JDBC target)
- [Phase 6 README](../phase6-istio/README.md) - Istio mesh (NiFi UI ingress)
- [nifi-crdb-installation](~/workspace/nifi-crdb-installation/) - EC2 reference installation
