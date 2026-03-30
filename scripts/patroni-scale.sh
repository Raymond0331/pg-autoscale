#!/bin/bash
#==============================================================================
# Patroni PostgreSQL Cluster Auto-Scaling Script
#
# Features:
# - Zero-downtime scaling: NEVER deletes existing nodes when scaling out
# - No failover: existing nodes keep their roles
# - New nodes join automatically via Raft
#
# Usage:
#   ./patroni-scale.sh status              - Show cluster status
#   ./patroni-scale.sh add <count>         - Add <count> new nodes
#   ./patroni-scale.sh remove <index>      - Remove pg-node-<index> (replica only)
#   ./patroni-scale.sh check               - Verify cluster health
#==============================================================================

set -e

# Configuration - MODIFY THESE VALUES FOR YOUR ENVIRONMENT
PROJECT_ID="your-gcp-project-id"
REGION="asia-northeast1"
ZONES=("asia-northeast1-a" "asia-northeast1-b")
MACHINE_TYPE="e2-standard-2"
NETWORK="pg-ha-vpc"
PG_PASSWORD="your-secure-password"

# Fixed internal IP pattern: 192.168.X.10 for pg-node-N
# Subnets: pg-subnet-1 through pg-subnet-5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_TEMPLATE="${SCRIPT_DIR}/startup-scaling.tpl"
LOCK_FILE="/tmp/patroni-scale.lock"

# Minimum nodes for Raft consensus (majority of 5 = 3)
MIN_NODES=3

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Acquire exclusive lock for cluster modifications
acquire_lock() {
    local lock_fd=200
    local lock_timeout=10
    local elapsed=0

    while [[ $elapsed -lt $lock_timeout ]]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            # Write PID to lock file for debugging
            echo $$ > "$LOCK_FILE/pid"
            return 0
        fi

        # Check if lock holder is still alive
        local lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            # Lock holder died, remove stale lock
            rm -rf "$LOCK_FILE"
            continue
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_error "Cannot acquire lock. Another operation in progress."
    log_info "Lock file: $LOCK_FILE"
    log_info "If no other operation is running, remove the lock: rm -rf $LOCK_FILE"
    exit 1
}

# Release lock
release_lock() {
    rm -rf "$LOCK_FILE"
}

# Ensure lock is released on exit
trap release_lock EXIT INT TERM

# Get list of existing node names
get_existing_nodes() {
    gcloud compute instances list --project="$PROJECT_ID" \
        --filter="name~pg-node AND status:RUNNING" \
        --format="value(name)" 2>/dev/null | tr -d '\r' | sort -V
}

# Get existing node IPs
get_existing_ips() {
    gcloud compute instances list --project="$PROJECT_ID" \
        --filter="name~pg-node AND status:RUNNING" \
        --format="value(networkInterfaces[0].networkIP)" 2>/dev/null | \
        tr -d '\r' | sort -V
}

# Get next available node index
get_next_index() {
    local max_index=0
    for node in $(get_existing_nodes); do
        local index=$(echo "$node" | sed 's/pg-node-//')
        if [[ "$index" =~ ^[0-9]+$ ]] && [[ $index -gt $max_index ]]; then
            max_index=$index
        fi
    done
    echo $((max_index + 1))
}

# Get zone for a node index (alternates between zones)
get_zone() {
    local index=$1
    local zone_index=$(( (index - 1) % ${#ZONES[@]} ))
    echo "${ZONES[$zone_index]}"
}

# Get subnet for a node index
get_subnet() {
    local index=$1
    local subnet_num=$(( (index - 1) % 5 + 1 ))
    echo "pg-subnet-$subnet_num"
}

# Get static IP for node index
get_static_ip() {
    local index=$1
    echo "192.168.${index}.10"
}

# Generate partner addresses string from existing IPs
build_partner_addrs() {
    local partner_list=""
    for ip in $(get_existing_ips); do
        if [[ -n "$ip" ]]; then
            partner_list="${partner_list}
    - ${ip}:2222"
        fi
    done
    echo "$partner_list"
}

# Generate startup script for a new node joining existing cluster
generate_startup_script() {
    local node_index=$1
    local current_ip=$(get_static_ip $node_index)
    local partner_addrs_val=$(build_partner_addrs)

    python3 - "$STARTUP_TEMPLATE" "$PG_PASSWORD" "pg-node-${node_index}" "$current_ip" "$partner_addrs_val" << 'PYEOF'
import sys

template_path = sys.argv[1]
pg_password = sys.argv[2]
node_name = sys.argv[3]
self_ip = sys.argv[4]
partner_addrs = sys.argv[5]

with open(template_path, 'r') as f:
    content = f.read()

content = content.replace("__PG_PASSWORD__", pg_password)
content = content.replace("__NODE_NAME__", node_name)
content = content.replace("__SELF_IP__", self_ip)
content = content.replace("__PARTNER_ADDRS__", partner_addrs)

sys.stdout.write(content)
PYEOF
}

# Wait for node to be running
wait_for_node() {
    local node_name=$1
    local timeout=${2:-180}

    log_info "Waiting for $node_name to be running..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local status=$(gcloud compute instances describe "$node_name" --project="$PROJECT_ID" --format="value(status)" 2>/dev/null || echo "NOT_FOUND")
        if [[ "$status" == "RUNNING" ]]; then
            log_info "$node_name is RUNNING"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    log_error "$node_name failed to start within ${timeout}s"
    return 1
}

# Wait for Patroni to initialize on node
wait_for_patroni() {
    local node_name=$1
    local zone=$2
    local timeout=${3:-180}

    log_info "Waiting for Patroni on $node_name to initialize..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        # Use serial port to check patronictl output
        local log_output=$(gcloud compute instances get-serial-port-output "$node_name" \
            --zone="$zone" --project="$PROJECT_ID" 2>/dev/null | tail -50)

        if echo "$log_output" | grep -q "I am.*the leader with the lock"; then
            log_info "$node_name is Leader"
            return 0
        elif echo "$log_output" | grep -q "I am.*a secondary"; then
            log_info "$node_name is Replica (joined cluster)"
            return 0
        elif echo "$log_output" | grep -q "failed to start patroni"; then
            log_error "$node_name Patroni failed to start"
            return 1
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done

    log_warn "$node_name Patroni status unknown after ${timeout}s"
    return 0  # Don't fail hard, node might still be initializing
}

# Deploy a single new node
deploy_node() {
    local node_index=$1
    local node_name="pg-node-${node_index}"
    local zone=$(get_zone $node_index)
    local subnet=$(get_subnet $node_index)
    local static_ip=$(get_static_ip $node_index)

    log_step "Deploying $node_name in $zone (IP: $static_ip)..."

    # Check if node already exists
    if gcloud compute instances describe "$node_name" --zone="$zone" --project="$PROJECT_ID" &>/dev/null; then
        log_warn "$node_name already exists, skipping"
        return 0
    fi

    # Generate startup script with current cluster info
    local startup_script_content
    startup_script_content=$(generate_startup_script $node_index)

    # Write to temp file
    local temp_script=$(mktemp)
    echo "$startup_script_content" > "$temp_script"

    # Create instance WITHOUT public IP
    gcloud compute instances create "$node_name" \
        --zone="$zone" \
        --project="$PROJECT_ID" \
        --machine-type="$MACHINE_TYPE" \
        --network-interface="network=$NETWORK,subnet=$subnet,private-network-ip=$static_ip,no-address" \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --boot-disk-size=50GB \
        --boot-disk-type=pd-ssd \
        --metadata-from-file="startup-script=$temp_script" \
        --quiet 2>&1

    rm -f "$temp_script"

    # Wait for node to start
    wait_for_node "$node_name" || true

    log_info "$node_name deployment complete"
}

# Add new nodes to cluster
add_nodes() {
    local count=${1:-1}

    # Acquire exclusive lock to prevent concurrent modifications
    acquire_lock

    local existing_nodes=$(get_existing_nodes | wc -l)
    local next_index=$(get_next_index)

    log_step "Current cluster: $existing_nodes nodes"
    log_step "Adding $count new node(s) starting from index $next_index"
    log_info "Existing nodes will NOT be modified (zero-downtime)"
    log_info "New nodes will join as Replicas via Raft"
    echo ""

    for i in $(seq 1 $count); do
        local node_index=$((next_index + i - 1))
        deploy_node $node_index

        # Small delay between deployments
        if [[ $i -lt $count ]]; then
            log_info "Waiting 30s before deploying next node..."
            sleep 30
        fi
    done

    echo ""
    log_step "Scale-out complete!"
    log_info "Cluster expanded from $existing_nodes to $((existing_nodes + count)) nodes"
    echo ""
    log_info "New nodes will automatically join the cluster within 2-3 minutes."
    log_info "Run './patroni-scale.sh status' to monitor progress."

    # Release lock before exiting
    release_lock
}

# Show cluster status
show_status() {
    echo ""
    echo "=========================================="
    echo "  Patroni Cluster Status"
    echo "=========================================="
    echo ""

    echo "GCP Instances:"
    gcloud compute instances list --project="$PROJECT_ID" \
        --filter="name~pg-node" \
        --format="table(name,zone.basename(),networkInterfaces[0].networkIP,status)" 2>/dev/null
    echo ""

    echo "Load Balancer:"
    gcloud compute forwarding-rules list --project="$PROJECT_ID" \
        --filter="name~pg" \
        --format="table(name,IPAddress,target)" 2>/dev/null || echo "  No forwarding rules"
    echo ""

    echo "Target Pool Members:"
    for pool in $(gcloud compute target-pools list --project="$PROJECT_ID" --filter="name~pg" --format="value(name)" 2>/dev/null); do
        echo "  Pool: $pool"
        gcloud compute target-pools describe "$pool" --region="$REGION" --project="$PROJECT_ID" \
            --format="value(instances)" 2>/dev/null | tr ',' '\n' | sed 's|.*/||' | while read instance; do
            echo "    - $instance"
        done
    done
    echo ""

    echo "Internal IPs of existing nodes:"
    for ip in $(get_existing_ips); do
        echo "  - $ip"
    done
    echo ""
}

# Check cluster health via serial port logs
check_cluster() {
    log_step "Checking cluster health via Patroni logs..."

    for node in $(get_existing_nodes); do
        local zone=$(gcloud compute instances describe "$node" --project="$PROJECT_ID" --format="value(zone)" 2>/dev/null | sed 's|.*/||')
        echo ""
        echo "=== $node ==="

        local log_output=$(gcloud compute instances get-serial-port-output "$node" \
            --zone="$zone" --project="$PROJECT_ID" 2>/dev/null | tail -30)

        if echo "$log_output" | grep -q "leader with the lock"; then
            echo "  Role: LEADER"
        elif echo "$log_output" | grep -q "a secondary"; then
            echo "  Role: REPLICA"
        elif echo "$log_output" | grep -q "running"; then
            echo "  Role: UNKNOWN (running)"
        else
            echo "  Status: checking..."
        fi
    done
}

# Get zone for a node name
get_node_zone() {
    local node_name=$1
    gcloud compute instances describe "$node_name" --project="$PROJECT_ID" --format="value(zone)" 2>/dev/null | sed 's|.*/||'
}

# Check if node is the leader
is_node_leader() {
    local node_name=$1
    local zone=$(get_node_zone "$node_name")

    local log_output=$(gcloud compute instances get-serial-port-output "$node_name" \
        --zone="$zone" --project="$PROJECT_ID" 2>/dev/null | tail -30)

    if echo "$log_output" | grep -q "leader with the lock"; then
        return 0  # is leader
    fi
    return 1  # not leader
}

# Check if node exists
node_exists() {
    local node_name=$1
    gcloud compute instances describe "$node_name" --project="$PROJECT_ID" --format="value(name)" 2>/dev/null | grep -q "$node_name"
}

# Remove node from target pool
remove_from_target_pool() {
    local node_name=$1

    for pool in $(gcloud compute target-pools list --project="$PROJECT_ID" --filter="name~pg" --format="value(name)" 2>/dev/null); do
        local instances=$(gcloud compute target-pools describe "$pool" --region="$REGION" --project="$PROJECT_ID" --format="value(instances)" 2>/dev/null)
        if echo "$instances" | grep -q "$node_name"; then
            log_info "Removing $node_name from target pool $pool..."
            gcloud compute target-pools remove-instances "$pool" \
                --region="$REGION" \
                --project="$PROJECT_ID" \
                --instances="$node_name" \
                --quiet 2>&1 || true
        fi
    done
}

# Remove a node from cluster
remove_node() {
    local node_index=$1
    local node_name="pg-node-${node_index}"

    if [[ -z "$node_index" ]]; then
        log_error "Node index is required"
        usage
        exit 1
    fi

    # Acquire exclusive lock to prevent concurrent modifications
    acquire_lock

    local current_nodes=$(get_existing_nodes | wc -l)

    log_step "Removing $node_name from cluster..."
    log_info "Current cluster size: $current_nodes nodes"

    # Check minimum nodes requirement for Raft consensus
    if [[ $current_nodes -le $MIN_NODES ]]; then
        log_error "Cannot remove node: cluster would have only $((current_nodes - 1)) nodes."
        log_error "Minimum $MIN_NODES nodes required for Raft consensus."
        release_lock
        exit 1
    fi

    # Check if node exists
    if ! node_exists "$node_name"; then
        log_error "$node_name does not exist"
        release_lock
        exit 1
    fi

    # Check if node is the leader
    if is_node_leader "$node_name"; then
        log_error "Cannot remove the leader node ($node_name)."
        log_error "First manually failover to a replica, then remove."
        release_lock
        exit 1
    fi

    log_info "$node_name is a replica, safe to remove"
    log_info "Removing from target pools (if any)..."
    remove_from_target_pool "$node_name"

    local zone=$(get_node_zone "$node_name")
    log_info "Deleting GCP instance $node_name in zone $zone..."

    gcloud compute instances delete "$node_name" \
        --zone="$zone" \
        --project="$PROJECT_ID" \
        --quiet 2>&1

    log_step "Node $node_name removed successfully!"
    log_info "Raft will automatically handle cluster reconfiguration."

    # Release lock before exiting
    release_lock
}

# Verify infrastructure exists
check_infrastructure() {
    log_info "Checking infrastructure..."

    if ! gcloud compute networks describe "$NETWORK" --project="$PROJECT_ID" &>/dev/null; then
        log_error "VPC $NETWORK does not exist. Run Terraform first."
        exit 1
    fi

    log_info "Infrastructure check passed"
}

# Usage
usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status          Show cluster status"
    echo "  add <count>     Add <count> new nodes (default: 1)"
    echo "  remove <index>  Remove node pg-node-<index> (must be a replica)"
    echo "  check           Check cluster health"
    echo ""
    echo "Examples:"
    echo "  $0 status       Show current status"
    echo "  $0 add 2        Add 2 new nodes"
    echo "  $0 remove 5     Remove pg-node-5 (replica only)"
    echo "  $0 check        Verify cluster health"
}

# Main
case "${1:-}" in
    add)
        check_infrastructure
        add_nodes ${2:-1}
        ;;
    remove)
        check_infrastructure
        remove_node ${2:-}
        ;;
    status)
        show_status
        ;;
    check)
        check_cluster
        ;;
    *)
        usage
        exit 1
        ;;
esac
