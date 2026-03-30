# Operations Manual

## Scaling Operations

### Scale-Out

```bash
./patroni-scale.sh add <count>
```

**Behavior**:
- New nodes join as REPLICA via Raft
- Existing nodes keep their current roles
- Zero downtime

**Example**:
```bash
# Add 1 node
./patroni-scale.sh add 1

# Add 3 nodes
./patroni-scale.sh add 3
```

### Scale-In

```bash
./patroni-scale.sh remove <node-index>
```

**Behavior**:
- Removes specified replica node
- Updates target pool automatically
- Raft handles cluster reconfiguration

**Safety Checks**:
- Cannot remove leader (must failover first)
- Cannot go below MIN_NODES (default: 3)
- Concurrent removals are blocked by lock

**Example**:
```bash
# Remove pg-node-5
./patroni-scale.sh remove 5
```

---

## Status Commands

### Show Cluster Status

```bash
./patroni-scale.sh status
```

Output:
- GCP VM instances list
- Load balancer configuration
- Target pool members
- Internal IPs

### Check Cluster Health

```bash
./patroni-scale.sh check
```

Shows Patroni role for each node:
- `LEADER` - Primary node
- `REPLICA` - Secondary/standby node
- `UNKNOWN` - Status unclear (check logs)

---

## Manual Failover

If you need to remove the current leader, first switch leadership:

```bash
# SSH to any replica node
gcloud compute ssh pg-node-2 --zone=asia-northeast1-b --project=YOUR_PROJECT

# Switchover to this node
sudo patronictl -c /etc/patroni/patroni.yml switchover

# Follow prompts to select new leader
```

---

## Node Recovery

### Rejoin Failed Node

If a node crashed and needs to rejoin:

```bash
# SSH to any existing node to check cluster
gcloud compute ssh pg-node-1 --zone=asia-northeast1-a --project=YOUR_PROJECT
patronictl -c /etc/patroni/patroni.yml list

# Delete the failed instance
gcloud compute instances delete pg-node-FAILED --zone=ZONE --project=YOUR_PROJECT --quiet

# Use scale-out to recreate
./patroni-scale.sh add 1
```

---

## Firewall Rules

| Rule Name | Purpose | CIDR |
|-----------|---------|------|
| allow-internal-db-ha | Internal PostgreSQL/Patroni/Raft access | 192.168.0.0/16 |
| allow-external-pg | External PostgreSQL (configure allowed_ips) | 0.0.0.0/0 |
| allow-lb-health-check | GCP LB health check | GCP health check ranges |

### Modify Allowed External IPs

Edit `variables.tf`:

```hcl
allowed_external_ips = ["your-office-ip/32"]
```

Then run:
```bash
terraform apply -auto-approve
```

---

## Monitoring

### Check Logs

```bash
# Serial port output (Patroni startup logs)
gcloud compute instances get-serial-port-output pg-node-1 --zone=asia-northeast1-a --project=YOUR_PROJECT

# Patroni logs on the node
gcloud compute ssh pg-node-1 --project=YOUR_PROJECT
sudo journalctl -u patroni -f
```

### Connect to PostgreSQL

```bash
# Via load balancer (writes go to leader)
psql -h EXTERNAL_IP -U postgres -d postgres

# Via internal IP (use replica for reads)
psql -h 192.168.1.10 -U postgres -d postgres
```

---

## Emergency Procedures

### Complete Cluster Failure

If all nodes failed:

1. Delete all instances:
   ```bash
   for i in {1..5}; do
     gcloud compute instances delete pg-node-$i --zone=asia-northeast1-a --project=YOUR_PROJECT --quiet 2>/dev/null
     gcloud compute instances delete pg-node-$i --zone=asia-northeast1-b --project=YOUR_PROJECT --quiet 2>/dev/null
   done
   ```

2. Run Terraform to recreate:
   ```bash
   terraform apply -auto-approve
   ```

### Lock File Issues

If script fails with "Cannot acquire lock":

```bash
rm -rf /tmp/patroni-scale.lock
```

---

## Cleanup

### Destroy All Resources

```bash
terraform destroy -auto-approve
```

Or manually:

```bash
# Delete instances
for i in {1..5}; do
  gcloud compute instances delete pg-node-$i --zone=asia-northeast1-a --project=YOUR_PROJECT --quiet 2>/dev/null
  gcloud compute instances delete pg-node-$i --zone=asia-northeast1-b --project=YOUR_PROJECT --quiet 2>/dev/null
done

# Delete load balancer resources
gcloud compute forwarding-rules delete pg-external-forwarding-rule --region=asia-northeast1 --project=YOUR_PROJECT --quiet
gcloud compute target-pools delete pg-pool --region=asia-northeast1 --project=YOUR_PROJECT --quiet
gcloud compute addresses delete pg-external-ip --region=asia-northeast1 --project=YOUR_PROJECT --quiet

# Delete network
gcloud compute networks delete pg-ha-vpc --project=YOUR_PROJECT --quiet
```
