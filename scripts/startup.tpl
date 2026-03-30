#!/bin/bash
set -e

# ============== CONFIG ==============
PG_PASSWORD="${pg_password}"
NODE_COUNT="${node_count}"
CLUSTER_IPS="${node_ips}"   # comma-separated: 192.168.1.10,192.168.2.10,...

# ============== GET METADATA ==============
CURRENT_IP=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
NODE_NAME=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/name)

echo "[$NODE_NAME] Starting bootstrap - IP: $CURRENT_IP"
echo "[$NODE_NAME] Cluster has $NODE_COUNT nodes: $CLUSTER_IPS"

# ============== GENERATE RAFT PARTNER_ADDRS ==============
PARTNER_ADDRS=""
IFS=',' read -ra IPS <<< "$CLUSTER_IPS"
for ip in "$${IPS[@]}"; do
  if [[ "$ip" != "$CURRENT_IP" && -n "$ip" ]]; then
    PARTNER_ADDRS="$${PARTNER_ADDRS}
    - $ip:2222"
  fi
done

echo "[$NODE_NAME] Partner addresses:$${PARTNER_ADDRS}"

# ============== INSTALL DEPENDENCIES ==============
echo "[$NODE_NAME] Installing dependencies..."
apt update
apt install -y curl gnupg python3-dev python3-pip software-properties-common \
  libpq-dev python3-psycopg2 chrony ca-certificates

systemctl enable chrony
systemctl start chrony

# ============== INSTALL POSTGRESQL ==============
echo "[$NODE_NAME] Installing PostgreSQL..."
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

apt update
apt install -y postgresql-18 || apt install -y postgresql-17

# Stop and mask default cluster
systemctl stop postgresql 2>/dev/null || true
systemctl disable postgresql 2>/dev/null || true
systemctl mask postgresql 2>/dev/null || true

PG_VERSION=$(ls -d /usr/lib/postgresql/*/bin/postgres 2>/dev/null | head -1 | sed 's|/usr/lib/postgresql/||; s|/bin/postgres||')
for ver in 18 17 16 15 14; do
  if pg_lsclusters | grep -q "^$ver "; then
    pg_dropcluster --stop $ver main 2>/dev/null || true
  fi
done
rm -rf /var/lib/postgresql/* 2>/dev/null || true

echo "[$NODE_NAME] PostgreSQL $PG_VERSION installed"

# ============== INSTALL PATRONI ==============
echo "[$NODE_NAME] Installing Patroni..."
pip3 install --break-system-packages "patroni[raft]==3.3.2" psycopg2-binary || true

mkdir -p /var/lib/patroni/raft
chown -R postgres:postgres /var/lib/patroni
mkdir -p /etc/patroni

PG_BIN="/usr/lib/postgresql/$PG_VERSION/bin"
PG_DATA="/var/lib/postgresql/$PG_VERSION/main"

# ============== WRITE PATRONI CONFIG ==============
cat > /etc/patroni/patroni.yml << PATRONIYML
scope: pg-ha-cluster
namespace: /service/
name: $NODE_NAME

restapi:
  listen: 0.0.0.0:8008
  connect_address: $CURRENT_IP:8008

raft:
  self_addr: $CURRENT_IP:2222
  data_dir: /var/lib/patroni/raft
  partner_addrs:$${PARTNER_ADDRS}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: true
      parameters:
        archive_mode: "on"
        wal_level: replica
        password_encryption: scram-sha-256
  initdb:
  - encoding: UTF8
  - data-checksums
  pg_hba:
  - local all all trust
  - host replication replicator 192.168.0.0/16 scram-sha-256
  - host all all 192.168.0.0/16 scram-sha-256
  - host all all 0.0.0.0/0 scram-sha-256
  users:
    postgres:
      password: __PG_PASSWORD__
      options:
        - superuser
    replicator:
      password: __PG_PASSWORD__
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $CURRENT_IP:5432
  data_dir: $PG_DATA
  bin_dir: $PG_BIN
  authentication:
    replication:
      username: replicator
      password: __PG_PASSWORD__
    superuser:
      username: postgres
      password: __PG_PASSWORD__
PATRONIYML

chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml

# Replace password placeholder
python3 -c "
import re
with open('/etc/patroni/patroni.yml', 'r') as f:
    content = f.read()
content = content.replace('__PG_PASSWORD__', '''$PG_PASSWORD''')
with open('/etc/patroni/patroni.yml', 'w') as f:
    f.write(content)
"

# ============== PATRONI SYSTEMD SERVICE ==============
cat > /etc/systemd/system/patroni.service << PATRONISYSTEMD
[Unit]
Description=Patroni PostgreSQL HA
After=network.target
Requires=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
PATRONISYSTEMD

systemctl daemon-reload
systemctl enable patroni

# ============== START PATRONI ==============
echo "[$NODE_NAME] Starting Patroni..."
systemctl start patroni

echo "[$NODE_NAME] Bootstrap complete!"
echo "  - Node IP: $CURRENT_IP"
echo "  - Node Name: $NODE_NAME"
echo "  - Raft Partner Addrs:$${PARTNER_ADDRS}"

sleep 30
patronictl -c /etc/patroni/patroni.yml list
