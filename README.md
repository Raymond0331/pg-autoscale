# Patroni PostgreSQL HA Cluster - Auto-Scaling Solution

## Project Overview

This project provides a zero-downtime auto-scaling solution for PostgreSQL High Availability clusters on Google Cloud Platform, powered by **Patroni** and **Raft consensus**.

### Key Features

- **Zero-Downtime Scaling**: Add or remove nodes without service interruption
- **No Failover on Scale-Out**: Existing nodes keep their roles when adding nodes
- **Raft-Based Consensus**: No external DCS (Distributed Configuration Store) required
- **Private Networking**: All nodes use internal IPs only; outbound via Cloud NAT
- **Load Balancer Integration**: External IP points to current leader for write operations

---

## Architecture

```
                         ┌─────────────────────────────────────┐
                         │         GCP External LB             │
                         │   (pg-external-forwarding-rule)     │
                         │         Port 5432 → Leader          │
                         └──────────────┬──────────────────────┘
                                        │ 34.x.x.x (Static External IP)
                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          pg-ha-vpc (Custom VPC)                          │
│  ┌──────────────┐                                                       │
│  │  Cloud NAT   │◄──── Egress (updates, apt, pip)                       │
│  └──────┬───────┘                                                       │
│         │                                                                │
│  ┌──────┴───────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │  pg-subnet-1 │  │  pg-subnet-2 │  │  pg-subnet-3 │                  │
│  │ 192.168.1.0/24│  │ 192.168.2.0/24│  │ 192.168.3.0/24│                  │
│  │              │  │              │  │              │                  │
│  │ pg-node-1    │  │ pg-node-2    │  │ pg-node-3    │                  │
│  │ (LEADER)     │  │ (REPLICA)    │  │ (REPLICA)    │                  │
│  │ 192.168.1.10 │  │ 192.168.2.10 │  │ 192.168.3.10 │                  │
│  └──────────────┘  └──────────────┘  └──────────────┘                  │
│         │                                                       Cloud Router
└─────────┼───────────────────────────────────────────────────────────────┘
          │
          │ More subnets: pg-subnet-4 (192.168.4.0/24), pg-subnet-5 (192.168.5.0/24)
          │ More nodes: pg-node-4, pg-node-5, ... up to pg-node-10
          │
```

### Components

| Component | Description |
|-----------|-------------|
| **Patroni** | PostgreSQL HA solution with Raft consensus |
| **Raft** | Distributed consensus protocol for leader election |
| **Cloud NAT** | Provides outbound internet for private nodes |
| **External LB** | Routes PostgreSQL traffic to current leader |
| **Target Pool** | Health-checked group of VM instances |

### Network Ports

| Port | Service | Access |
|------|---------|--------|
| 5432 | PostgreSQL | Internal network + External LB |
| 8008 | Patroni REST API | Internal network (health checks) |
| 2222 | Raft | Internal network only |
| 22 | SSH | IAP tunnel only |

---

## Deployment

### Prerequisites

1. **GCP Project** with billing enabled
2. **gcloud CLI** authenticated (`gcloud auth login`)
3. **Terraform** >= 1.0 installed
4. **SSH key pair** for VM access (optional)

### Configuration

1. Copy and configure Terraform variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
project_id         = "your-gcp-project-id"
region             = "asia-northeast1"
pg_password        = "your-secure-password"
node_count         = 3
machine_type       = "e2-standard-2"
```

2. Configure the scaling script:

Edit `scripts/patroni-scale.sh`:

```bash
PROJECT_ID="your-gcp-project-id"
PG_PASSWORD="your-secure-password"
```

### Deployment Steps

```bash
# Initialize Terraform
terraform init

# Plan deployment
terraform plan -out=tfplan

# Apply deployment
terraform apply -auto-approve

# Verify cluster
./scripts/patroni-scale.sh status
```

---

## Operations

### Scaling Out (Add Nodes)

```bash
# Add single node
./scripts/patroni-scale.sh add 1

# Add multiple nodes
./scripts/patroni-scale.sh add 3

# Check status
./scripts/patroni-scale.sh status
./scripts/patroni-scale.sh check
```

New nodes join as **replicas** via Raft. Existing nodes keep their roles.

### Scaling In (Remove Nodes)

```bash
# Remove a replica node
./scripts/patroni-scale.sh remove 5

# Check status
./scripts/patroni-scale.sh status
```

**Restrictions**:
- Cannot remove the leader node
- Cannot reduce below minimum nodes (3)
- Concurrent removals are blocked by a lock

### Health Check

```bash
./scripts/patroni-scale.sh check
```

---

## File Structure

```
pg_autoscale/
├── main.tf              # VPC, Subnets, NAT, Firewall, Secret Manager
├── compute.tf           # VM instances, Load Balancer, Target Pool
├── variables.tf         # Input variables
├── outputs.tf           # Terraform outputs
├── terraform.tfvars     # Configuration (gitignored)
├── scripts/
│   ├── patroni-scale.sh     # Auto-scaling script
│   ├── startup.tpl          # Terraform initial deployment startup
│   └── startup-scaling.tpl  # Scaling (add node) startup template
└── docs/
    ├── README.md            # This file
    ├── [README_CN.md](./docs/README_CN.md)         # 中文文档 (Chinese documentation)
    └── OPERATIONS.md        # Detailed operations guide
```

---

## Security

- **No Public IPs**: All VM instances use `--no-address` flag
- **Cloud NAT**: Outbound-only internet access for private instances
- **Firewall**: Only allows internal network (192.168.0.0/16) and LB health checks
- **IAP**: SSH access only through Identity-Aware Proxy
- **Secrets**: PostgreSQL password stored in GCP Secret Manager

---

## Troubleshooting

### Node won't join cluster

1. Check if the node is running:
   ```bash
   gcloud compute instances list --filter="name~pg-node"
   ```

2. Check serial port output:
   ```bash
   gcloud compute instances get-serial-port-output pg-node-X --zone=ZONE
   ```

3. Verify network connectivity between nodes

### Leader election issues

1. Check Raft connectivity:
   ```bash
   # SSH to node and check
   patronictl -c /etc/patroni/patroni.yml list
   ```

2. Ensure at least majority of nodes are healthy

### Scale-out fails

1. Check if VPC network exists:
   ```bash
   gcloud compute networks describe pg-ha-vpc
   ```

2. Verify subnet capacity (max 10 nodes with current config)

---

## License

MIT License
