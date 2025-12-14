#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               01-setup-elk.sh
#
#  The "Architect" script for the ELK Stack.
#
#  1. Kernel: Enforces vm.max_map_count=262144.
#  2. Secrets: Generates Passwords & Encryption Keys.
#  3. Preparation: Temporarily owns config dirs for writing.
#  4. Configs: Generates configs with properly expanded variables.
#  5. Permissions: Enforces strict ownership (Root/UID 1000) at the end.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# Source Certificate Paths
CA_DIR="$HOST_CICD_ROOT/ca"
SRC_CA_CRT="$CA_DIR/pki/certs/ca.pem"

SRC_ES_CRT="$CA_DIR/pki/services/elk/elasticsearch.cicd.local/elasticsearch.cicd.local.crt.pem"
SRC_ES_KEY="$CA_DIR/pki/services/elk/elasticsearch.cicd.local/elasticsearch.cicd.local.key.pem"

SRC_KIB_CRT="$CA_DIR/pki/services/elk/kibana.cicd.local/kibana.cicd.local.crt.pem"
SRC_KIB_KEY="$CA_DIR/pki/services/elk/kibana.cicd.local/kibana.cicd.local.key.pem"

# Config Destinations
ES_CONFIG_DIR="$ELK_BASE/elasticsearch/config"
KIBANA_CONFIG_DIR="$ELK_BASE/kibana/config"
FILEBEAT_CONFIG_DIR="$ELK_BASE/filebeat/config"

echo "🚀 Starting ELK 'Architect' Setup..."

# --- 2. Host Kernel Tuning ---
echo "--- Phase 1: Kernel Tuning ---"
REQUIRED_MAP_COUNT=262144
SYSCTL_CONF="/etc/sysctl.conf"

CURRENT_MAP_COUNT=$(sudo sysctl -n vm.max_map_count)
if [ "$CURRENT_MAP_COUNT" -lt "$REQUIRED_MAP_COUNT" ]; then
    echo "Updating runtime limit..."
    sudo sysctl -w vm.max_map_count=$REQUIRED_MAP_COUNT
else
    echo "Runtime limit sufficient."
fi

if ! grep -q "vm.max_map_count=$REQUIRED_MAP_COUNT" "$SYSCTL_CONF"; then
    echo "Persisting limit in $SYSCTL_CONF..."
    # Remove old entry if exists (simplistic approach) or append
    sudo sed -i '/vm.max_map_count/d' "$SYSCTL_CONF"
    echo "vm.max_map_count=$REQUIRED_MAP_COUNT" | sudo tee -a "$SYSCTL_CONF" > /dev/null
fi

# --- 3. Directory & Secrets Setup ---
echo "--- Phase 2: Secrets & Directories ---"

# Create scaffolding
sudo mkdir -p "$ES_CONFIG_DIR/certs"
sudo mkdir -p "$KIBANA_CONFIG_DIR/certs"
sudo mkdir -p "$FILEBEAT_CONFIG_DIR/certs"

# Secrets Generation
if [ ! -f "$MASTER_ENV_FILE" ]; then touch "$MASTER_ENV_FILE"; fi

key_exists() { grep -q "^$1=" "$MASTER_ENV_FILE"; }
generate_secret() { openssl rand -hex 32; }
generate_password() { openssl rand -hex 16; }

update_env=false

if ! key_exists "ELASTIC_PASSWORD"; then
    echo "ELASTIC_PASSWORD=\"$(generate_password)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi
if ! key_exists "KIBANA_PASSWORD"; then
    echo "KIBANA_PASSWORD=\"$(generate_password)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi
if ! key_exists "XPACK_SECURITY_ENCRYPTIONKEY"; then
    echo "XPACK_SECURITY_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    echo "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    echo "XPACK_REPORTING_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi

if [ "$update_env" = true ]; then echo "Secrets generated."; else echo "Secrets loaded."; fi

set -a; source "$MASTER_ENV_FILE"; set +a

# --- 4. Ownership Handoff (The Fix) ---
echo "--- Phase 3: Ownership Handoff ---"
# We recursively change ownership to the current user so we can write configs/certs
# without sudo. This ensures environment variables are preserved during writing.
CURRENT_USER=$(id -u)
CURRENT_GROUP=$(id -g)
sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" "$ELK_BASE"

# --- 5. Staging Certificates ---
echo "--- Phase 4: Staging Certificates ---"
# Now we can just use cp because we own the destination
cp "$SRC_ES_CRT" "$ES_CONFIG_DIR/certs/elasticsearch.crt"
cp "$SRC_ES_KEY" "$ES_CONFIG_DIR/certs/elasticsearch.key"
cp "$SRC_CA_CRT" "$ES_CONFIG_DIR/certs/ca.pem"

cp "$SRC_KIB_CRT" "$KIBANA_CONFIG_DIR/certs/kibana.crt"
cp "$SRC_KIB_KEY" "$KIBANA_CONFIG_DIR/certs/kibana.key"
cp "$SRC_CA_CRT"  "$KIBANA_CONFIG_DIR/certs/ca.pem"

cp "$SRC_CA_CRT"  "$FILEBEAT_CONFIG_DIR/certs/ca.pem"

# --- 6. Configuration Generation ---
echo "--- Phase 5: Generating Config Files ---"

# A. Elasticsearch
# No variables needed here, but writing as user is safer
cat << EOF > "$ES_CONFIG_DIR/elasticsearch.yml"
cluster.name: "cicd-elk"
node.name: "elasticsearch.cicd.local"
network.host: 0.0.0.0
discovery.type: single-node

path.data: /usr/share/elasticsearch/data
path.logs: /usr/share/elasticsearch/logs

xpack.security.enabled: true

xpack.security.http.ssl:
  enabled: true
  key: /usr/share/elasticsearch/config/certs/elasticsearch.key
  certificate: /usr/share/elasticsearch/config/certs/elasticsearch.crt
  certificate_authorities: [ "/usr/share/elasticsearch/config/certs/ca.pem" ]

xpack.security.transport.ssl:
  enabled: true
  key: /usr/share/elasticsearch/config/certs/elasticsearch.key
  certificate: /usr/share/elasticsearch/config/certs/elasticsearch.crt
  certificate_authorities: [ "/usr/share/elasticsearch/config/certs/ca.pem" ]

ingest.geoip.downloader.enabled: false
EOF

# B. Kibana
# Note: We escape \${VAR} for Docker runtime variables.
# We use $VAR (no escape) for values we want to hardcode NOW (from this script).
cat << EOF > "$KIBANA_CONFIG_DIR/kibana.yml"
server.host: "0.0.0.0"
server.name: "kibana.cicd.local"
server.publicBaseUrl: "https://kibana.cicd.local:5601"

server.ssl.enabled: true
server.ssl.certificate: "/usr/share/kibana/config/certs/kibana.crt"
server.ssl.key: "/usr/share/kibana/config/certs/kibana.key"
server.ssl.certificateAuthorities: ["/usr/share/kibana/config/certs/ca.pem"]

elasticsearch.hosts: [ "https://elasticsearch.cicd.local:9200" ]
elasticsearch.ssl.certificateAuthorities: [ "/usr/share/kibana/config/certs/ca.pem" ]
elasticsearch.username: "kibana_system"
elasticsearch.password: "\${ELASTICSEARCH_PASSWORD}"

# These are hardcoded from the secrets file immediately
xpack.security.encryptionKey: "$XPACK_SECURITY_ENCRYPTIONKEY"
xpack.encryptedSavedObjects.encryptionKey: "$XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY"
xpack.reporting.encryptionKey: "$XPACK_REPORTING_ENCRYPTIONKEY"

telemetry.enabled: false
telemetry.optIn: false
newsfeed.enabled: false
map.includeElasticMapsService: false
xpack.fleet.enabled: false
xpack.apm.enabled: false

xpack.actions.preconfigured:
  mattermost-webhook:
    name: "Mattermost CI/CD Channel"
    actionTypeId: .webhook
    config:
      url: "\${MATTERMOST_WEBHOOK_URL}"
      method: post
      hasAuth: false
EOF

# C. Filebeat
# CRITICAL FIX: We use $ELASTIC_PASSWORD (unescaped).
# This injects the ACTUAL password string into the file, bypassing Docker variable expansion issues.
cat << EOF > "$FILEBEAT_CONFIG_DIR/filebeat.yml"
filebeat.inputs:
  # 1. Host System Logs (Journald)
  # Reads binary logs directly from /var/log/journal
  - type: journald
    id: host-system
    paths:
      - /var/log/journal
    include_matches:
      - "systemd.unit=docker.service"
      - "systemd.unit=sudo.service"
      - "systemd.unit=ssh.service"
      - "syslog.identifier=kernel"
    fields: { service_name: "system" }
    fields_under_root: true

  # 2. GitLab Nginx
  - type: filestream
    id: gitlab-nginx
    paths:
      - /host_volumes/gitlab-logs/_data/nginx/*access.log
      - /host_volumes/gitlab-logs/_data/nginx/*error.log
    fields: { service_name: "gitlab-nginx" }
    fields_under_root: true

  # 3. SonarQube CE
  - type: filestream
    id: sonarqube-ce
    paths:
      - /host_volumes/sonarqube-logs/_data/ce.log
    fields: { service_name: "sonarqube" }
    fields_under_root: true
    multiline.type: pattern
    multiline.pattern: '^\d{4}.\d{2}.\d{2}'
    multiline.negate: true
    multiline.match: after

  # 4. Mattermost
  - type: filestream
    id: mattermost
    paths:
      - /host_volumes/mattermost-logs/_data/mattermost.log
    fields: { service_name: "mattermost" }
    fields_under_root: true

  # 5. Artifactory
  - type: filestream
    id: artifactory
    paths:
      - /host_volumes/artifactory-data/_data/log/artifactory-service.log
      - /host_volumes/artifactory-data/_data/log/artifactory-request.log
      - /host_volumes/artifactory-data/_data/log/access-service.log
    fields: { service_name: "artifactory" }
    fields_under_root: true
    multiline.type: pattern
    multiline.pattern: '^\d{4}-\d{2}-\d{2}'
    multiline.negate: true
    multiline.match: after

output.elasticsearch:
  hosts: ["https://elasticsearch.cicd.local:9200"]
  pipeline: "cicd-logs"
  protocol: "https"
  ssl.certificate_authorities: ["/usr/share/filebeat/certs/ca.pem"]
  username: "elastic"
  password: "$ELASTIC_PASSWORD"

setup.ilm.enabled: false
setup.template.enabled: false
EOF

# --- 7. Env Files ---
echo "--- Phase 6: Scoped Env Files ---"
# Writing these as user is fine, we fix permissions later.
cat << EOF > "$ELK_BASE/elasticsearch/elasticsearch.env"
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
ES_JAVA_OPTS=-Xms1g -Xmx1g
EOF

cat << EOF > "$ELK_BASE/kibana/kibana.env"
ELASTICSEARCH_PASSWORD=$KIBANA_PASSWORD
XPACK_SECURITY_ENCRYPTIONKEY=$XPACK_SECURITY_ENCRYPTIONKEY
XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=$XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY
XPACK_REPORTING_ENCRYPTIONKEY=$XPACK_REPORTING_ENCRYPTIONKEY
MATTERMOST_WEBHOOK_URL=$SONAR_MATTERMOST_WEBHOOK
EOF

cat << EOF > "$ELK_BASE/filebeat/filebeat.env"
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
EOF

# --- 8. Final Permissions Lockdown (CRITICAL) ---
echo "--- Phase 7: Locking Down Permissions ---"

# Secure the Keys (600) and Certs (644)
chmod 600 "$ES_CONFIG_DIR/certs/"*.key
chmod 600 "$KIBANA_CONFIG_DIR/certs/"*.key
chmod 644 "$ES_CONFIG_DIR/certs/"*.crt
chmod 644 "$KIBANA_CONFIG_DIR/certs/"*.crt
chmod 644 "$FILEBEAT_CONFIG_DIR/certs/"*.pem

# Secure Env Files (600 - Owner Only)
chmod 600 "$ELK_BASE"/*/*.env

# Apply Ownership
# Elasticsearch & Kibana (UID 1000)
sudo chown -R 1000:0 "$ES_CONFIG_DIR"
sudo chown -R 1000:0 "$KIBANA_CONFIG_DIR"
sudo chown 1000:0 "$ELK_BASE/elasticsearch/elasticsearch.env"
sudo chown 1000:0 "$ELK_BASE/kibana/kibana.env"

# Filebeat (Root) - REQUIRED for startup
sudo chown -R root:root "$FILEBEAT_CONFIG_DIR"
sudo chown root:root "$ELK_BASE/filebeat/filebeat.env"

# Enforce Filebeat Config Perms (Must be 0644 or 0600)
sudo chmod 644 "$FILEBEAT_CONFIG_DIR/filebeat.yml"
# Allow Env files to be readable by the specific containers
sudo chmod 644 "$ELK_BASE/elasticsearch/elasticsearch.env"
sudo chmod 644 "$ELK_BASE/kibana/kibana.env"
sudo chmod 644 "$ELK_BASE/filebeat/filebeat.env"

echo "✅ Architect Setup Complete."