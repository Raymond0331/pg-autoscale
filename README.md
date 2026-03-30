# pg-autoscale

**Zero-Downtime Auto-Scaling for Patroni PostgreSQL Clusters on GCP**

[![MIT License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Patroni PostgreSQL HA cluster with automatic scaling on Google Cloud Platform. Built on Raft consensus for true high availability without external dependencies.

## Features

- **Zero-Downtime Scaling** - Add or remove nodes without service interruption
- **No Failover on Scale-Out** - Existing nodes keep their roles when adding nodes
- **Raft-Based** - No external DCS (etcd, Consul) required
- **Private Network** - All nodes use internal IPs; outbound via Cloud NAT
- **Load Balancer Integration** - External IP always points to current leader

## Architecture

```
                    ┌─────────────────────────────────┐
                    │      GCP External Load Balancer │
                    │      Port 5432 → Leader         │
                    └──────────────┬──────────────────┘
                                   │ 34.x.x.x (Static IP)
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                         pg-ha-vpc (VPC)                             │
│  ┌──────────┐                                                       │
│  │Cloud NAT │◄──── Egress (updates, apt, pip)                      │
│  └────┬─────┘                                                       │
│       │                                                              │
│  ┌────┴────┐  ┌──────────┐  ┌──────────┐                           │
│  │ pg-sub-1│  │ pg-sub-2│  │ pg-sub-3│                           │
│  │192.168.1│  │192.168.2│  │192.168.3│                           │
│  │ pg-node-1│  │ pg-node-2│  │ pg-node-3│                           │
│  │ (LEADER) │  │ (REPLICA)│  │ (REPLICA)│                           │
│  └──────────┘  └──────────┘  └──────────┘                           │
└────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- GCP Project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth login`)
- Terraform >= 1.0 installed

## Quick Start

### 1. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
project_id    = "your-gcp-project-id"
region        = "asia-northeast1"
pg_password   = "your-secure-password"
node_count    = 3
machine_type  = "e2-standard-2"
```

### 2. Deploy

```bash
terraform init
terraform apply -auto-approve
```

### 3. Connect

```bash
# Get external IP
terraform output external_ip

# Connect to PostgreSQL
psql -h <EXTERNAL_IP> -U postgres -d postgres
```

### 4. Scale Out

```bash
./scripts/patroni-scale.sh add 2
```

## Usage Examples

### Scale Out (Add Nodes)

```bash
# Add 1 node
./scripts/patroni-scale.sh add 1

# Add 3 nodes at once
./scripts/patroni-scale.sh add 3

# Check cluster status
./scripts/patroni-scale.sh status
./scripts/patroni-scale.sh check
```

### Scale In (Remove Nodes)

```bash
# Remove a replica node
./scripts/patroni-scale.sh remove 5

# View current status
./scripts/patroni-scale.sh status
```

### Connect to PostgreSQL

```bash
# Via load balancer (writes go to leader)
psql -h $(terraform output -raw external_ip) -U postgres -d postgres

# Via internal IP on a replica (for reads)
psql -h 192.168.1.10 -U postgres -d postgres
```

### Manual Failover

```bash
# SSH to a replica node
gcloud compute ssh pg-node-2 --zone=asia-northeast1-b --project=YOUR_PROJECT

# Switchover leadership
sudo patronictl -c /etc/patroni/patroni.yml switchover
```

## Scaling Behavior

| Operation | Behavior |
|-----------|----------|
| **Scale Out** | New nodes join as replicas via Raft. Existing nodes keep roles. Zero downtime. |
| **Scale In** | Removes replica nodes. Raft automatically reconfigures. Leader cannot be removed directly. |
| **Min Nodes** | 3 (required for Raft quorum) |
| **Max Nodes** | 10 (subnet capacity) |

## File Structure

```
pg-autoscale/
├── main.tf              # VPC, Subnets, NAT, Firewall, Secret Manager
├── compute.tf          # VM instances, Load Balancer, Target Pool
├── variables.tf        # Input variables
├── outputs.tf          # Terraform outputs
├── terraform.tfvars.example
├── scripts/
│   ├── patroni-scale.sh     # Auto-scaling script
│   ├── startup.tpl           # Initial deployment startup
│   └── startup-scaling.tpl   # Scaling (add node) startup template
└── docs/
    ├── README.md             # This file
    ├── README_CN.md          # 中文文档
    └── OPERATIONS.md         # Detailed operations guide
```

## Security

- **No Public IPs** on VM instances (`--no-address`)
- **Cloud NAT** for outbound-only internet
- **Firewall** allows only internal network (192.168.0.0/16) and LB health checks
- **IAP** for SSH access (no direct SSH)
- **Secrets** stored in GCP Secret Manager

## Troubleshooting

### Node won't join cluster

```bash
# Check if node is running
gcloud compute instances list --filter="name~pg-node"

# Check serial port output
gcloud compute instances get-serial-port-output pg-node-1 --zone=asia-northeast1-a
```

### Leader election issues

```bash
# SSH to any node and check Raft status
patronictl -c /etc/patroni/patroni.yml list
```

### Lock file issues

```bash
# If script fails with "Cannot acquire lock"
rm -rf /tmp/patroni-scale.lock
```

## Cleanup

```bash
# Destroy all resources
terraform destroy -auto-approve
```

## License

MIT
