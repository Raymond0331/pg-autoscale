#!/bin/bash
set -e

# ============== CONFIG ==============
PG_PASSWORD="__PG_PASSWORD__"
NODE_NAME="__NODE_NAME__"
SELF_IP="__SELF_IP__"
PARTNER_ADDRS="__PARTNER_ADDRS__"

echo "[$NODE_NAME] Starting bootstrap..."
echo "[$NODE_NAME] Self IP: $SELF_IP"

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
# NOTE: When joining an EXISTING cluster, only the 'raft' section matters for discovery.
# The 'bootstrap.dcs' section is only used when initializing a NEW cluster.
cat > /etc/patroni/patroni.yml << PATRONIYML
scope: pg-ha-cluster
namespace: /service/
name: $NODE_NAME

restapi:
  listen: 0.0.0.0:8008
  connect_address: $SELF_IP:8008

raft:
  self_addr: $SELF_IP:2222
  data_dir: /var/lib/patroni/raft
  partner_addrs:${PARTNER_ADDRS}

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
      password: $PG_PASSWORD
      options:
        - superuser
    replicator:
      password: $PG_PASSWORD
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $SELF_IP:5432
  data_dir: $PG_DATA
  bin_dir: $PG_BIN
  authentication:
    replication:
      username: replicator
      password: $PG_PASSWORD
    superuser:
      username: postgres
      password: $PG_PASSWORD
PATRONIYML

chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml

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
echo "  - Node Name: $NODE_NAME"
echo "  - Self IP: $SELF_IP"
echo "  - Partner Addrs:${PARTNER_ADDRS}"

# Wait for Patroni to initialize and join cluster
echo "[$NODE_NAME] Waiting for Patroni to initialize (max 120s)..."
for i in {1..24}; do
    sleep 5
    PATRONI_STATUS=$(patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
    if echo "$PATRONI_STATUS" | grep -q "$NODE_NAME"; then
        echo "[$NODE_NAME] Patroni initialized successfully!"
        echo "$PATRONI_STATUS"
        break
    fi
    echo "[$NODE_NAME] Waiting... ($i/24)"
done

# Final status check
echo ""
echo "=== Final Patroni Status ==="
patronictl -c /etc/patroni/patroni.yml list || echo "Warning: Failed to get final status"
