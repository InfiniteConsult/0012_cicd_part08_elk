#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               01-setup-elk.sh (Final v9.2.2)
#
#  The "Architect" script for the ELK Stack.
#
#  1. Kernel: Enforces vm.max_map_count=262144 (Idempotent).
#  2. Secrets: Generates Passwords & Encryption Keys in cicd.env.
#  3. Certs: Stages distinct keys for ES and Kibana from CA.
#  4. Configs: Generates elasticsearch.yml, kibana.yml, filebeat.yml.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# Source Certificate Paths (Based on 'tree' output)
CA_DIR="$HOST_CICD_ROOT/ca"
SRC_CA_CRT="$CA_DIR/pki/certs/ca.pem"

# Distinct Service Certificates
SRC_ES_CRT="$CA_DIR/pki/services/elk/elasticsearch.cicd.local/elasticsearch.cicd.local.crt.pem"
SRC_ES_KEY="$CA_DIR/pki/services/elk/elasticsearch.cicd.local/elasticsearch.cicd.local.key.pem"

SRC_KIB_CRT="$CA_DIR/pki/services/elk/kibana.cicd.local/kibana.cicd.local.crt.pem"
SRC_KIB_KEY="$CA_DIR/pki/services/elk/kibana.cicd.local/kibana.cicd.local.key.pem"

# Config Destinations
ES_CONFIG_DIR="$ELK_BASE/elasticsearch/config"
KIBANA_CONFIG_DIR="$ELK_BASE/kibana/config"
FILEBEAT_CONFIG_DIR="$ELK_BASE/filebeat/config"

echo "🚀 Starting ELK 'Architect' Setup..."

# --- 2. Host Kernel Tuning (Idempotent Fix) ---
echo "--- Phase 1: Kernel Tuning ---"
REQUIRED_MAP_COUNT=262144
SYSCTL_CONF="/etc/sysctl.conf"

# A. Runtime Check
CURRENT_MAP_COUNT=$(sudo sysctl -n vm.max_map_count)

if [ "$CURRENT_MAP_COUNT" -lt "$REQUIRED_MAP_COUNT" ]; then
    echo "Runtime limit too low ($CURRENT_MAP_COUNT). Updating immediately..."
    sudo sysctl -w vm.max_map_count=$REQUIRED_MAP_COUNT
else
    echo "Runtime limit is sufficient ($CURRENT_MAP_COUNT)."
fi

# B. Persistence Check
echo "    Checking persistence in $SYSCTL_CONF..."

if grep -q "^\s*vm.max_map_count" "$SYSCTL_CONF"; then
    # Entry exists, check its value
    STORED_VAL=$(grep "^\s*vm.max_map_count" "$SYSCTL_CONF" | awk -F= '{print $2}' | tr -d '[:space:]')

    if [[ "$STORED_VAL" -lt "$REQUIRED_MAP_COUNT" ]]; then
        echo "Stored value ($STORED_VAL) is too low. Updating config in-place..."
        sudo sed -i "s/^\s*vm.max_map_count.*/vm.max_map_count=$REQUIRED_MAP_COUNT/" "$SYSCTL_CONF"
    else
        echo "Stored configuration is sufficient ($STORED_VAL)."
    fi
else
    # Entry missing, append it
    echo "Value missing. Appending to config..."
    echo "vm.max_map_count=$REQUIRED_MAP_COUNT" | sudo tee -a "$SYSCTL_CONF" > /dev/null
fi

# --- 3. Directory Setup ---
echo "--- Phase 2: Directory Scaffolding ---"
mkdir -p "$ES_CONFIG_DIR/certs"
mkdir -p "$KIBANA_CONFIG_DIR/certs"
mkdir -p "$FILEBEAT_CONFIG_DIR/certs"

# --- 4. Secrets Management ---
echo "--- Phase 3: Secrets Generation ---"

if [ ! -f "$MASTER_ENV_FILE" ]; then
    touch "$MASTER_ENV_FILE"
fi

# Helper to check if key exists
key_exists() { grep -q "^$1=" "$MASTER_ENV_FILE"; }

update_env=false

generate_secret() { openssl rand -hex 32; }
generate_password() { openssl rand -hex 16; }

# 4a. User Passwords
if ! key_exists "ELASTIC_PASSWORD"; then
    echo "Generating ELASTIC_PASSWORD..."
    echo "ELASTIC_PASSWORD=\"$(generate_password)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi

if ! key_exists "KIBANA_PASSWORD"; then
    echo "Generating KIBANA_PASSWORD..."
    echo "KIBANA_PASSWORD=\"$(generate_password)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi

# 4b. Kibana Encryption Keys (Critical for Persistence)
if ! key_exists "XPACK_SECURITY_ENCRYPTIONKEY"; then
    echo "Generating Persistence Keys..."
    echo "XPACK_SECURITY_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    echo "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    echo "XPACK_REPORTING_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi

if [ "$update_env" = true ]; then
    echo "Secrets updated in cicd.env"
else
    echo "Secrets already exist."
fi

# Load secrets for templating below
set -a; source "$MASTER_ENV_FILE"; set +a

# --- 5. Certificate Staging ---
echo "--- Phase 4: Staging Certificates ---"

# Validate existence
if [ ! -f "$SRC_ES_CRT" ] || [ ! -f "$SRC_ES_KEY" ]; then
    echo "ERROR: Elasticsearch certificates not found at:"
    echo "  $SRC_ES_CRT"
    echo "Please ensure Article 2 setup is complete."
    exit 1
fi
if [ ! -f "$SRC_KIB_CRT" ] || [ ! -f "$SRC_KIB_KEY" ]; then
    echo "ERROR: Kibana certificates not found at:"
    echo "  $SRC_KIB_CRT"
    exit 1
fi

# A. Elasticsearch Certs
echo "Staging Elasticsearch certificates..."
cp "$SRC_ES_CRT" "$ES_CONFIG_DIR/certs/elasticsearch.crt"
cp "$SRC_ES_KEY" "$ES_CONFIG_DIR/certs/elasticsearch.key"
cp "$SRC_CA_CRT" "$ES_CONFIG_DIR/certs/ca.pem"

# B. Kibana Certs
echo "Staging Kibana certificates..."
cp "$SRC_KIB_CRT" "$KIBANA_CONFIG_DIR/certs/kibana.crt"
cp "$SRC_KIB_KEY" "$KIBANA_CONFIG_DIR/certs/kibana.key"
cp "$SRC_CA_CRT"  "$KIBANA_CONFIG_DIR/certs/ca.pem"

# C. Filebeat Certs (Client only, needs CA)
echo "Staging Filebeat CA..."
cp "$SRC_CA_CRT"  "$FILEBEAT_CONFIG_DIR/certs/ca.pem"

# D. Permissions (Fixing for UID 1000)
# We set ownership to 1000:0 (User: 1000, Group: Root) so the container user can read them.
echo "Fixing certificate permissions for UID 1000 (Requires Sudo)..."
sudo chown -R 1000:0 "$ES_CONFIG_DIR/certs"
sudo chown -R 1000:0 "$KIBANA_CONFIG_DIR/certs"
sudo chown -R 0:0    "$FILEBEAT_CONFIG_DIR/certs" # Filebeat runs as root

# Secure Keys (600), Public Certs (644)
sudo chmod 600 "$ES_CONFIG_DIR/certs/"*.key
sudo chmod 600 "$KIBANA_CONFIG_DIR/certs/"*.key
sudo chmod 644 "$ES_CONFIG_DIR/certs/"*.crt
sudo chmod 644 "$KIBANA_CONFIG_DIR/certs/"*.crt

# --- 6. Configuration Generation ---
echo "--- Phase 5: Generating Config Files ---"

# A. Elasticsearch Configuration
cat << EOF > "$ES_CONFIG_DIR/elasticsearch.yml"
cluster.name: "cicd-elk"
node.name: "elasticsearch.cicd.local"
network.host: 0.0.0.0
discovery.type: single-node

path.data: /usr/share/elasticsearch/data
path.logs: /usr/share/elasticsearch/logs

# Security (TLS Everywhere)
xpack.security.enabled: true

# HTTP (Client/Kibana to Node)
xpack.security.http.ssl:
  enabled: true
  key: /usr/share/elasticsearch/config/certs/elasticsearch.key
  certificate: /usr/share/elasticsearch/config/certs/elasticsearch.crt
  certificate_authorities: [ "/usr/share/elasticsearch/config/certs/ca.pem" ]

# Transport (Node to Node - Required)
xpack.security.transport.ssl:
  enabled: true
  key: /usr/share/elasticsearch/config/certs/elasticsearch.key
  certificate: /usr/share/elasticsearch/config/certs/elasticsearch.crt
  certificate_authorities: [ "/usr/share/elasticsearch/config/certs/ca.pem" ]

# Air-Gap Optimization
ingest.geoip.downloader.enabled: false
EOF

# B. Kibana Configuration
# Using \${VAR} syntax maps to the Env Vars we inject in the Deploy script
cat << EOF > "$KIBANA_CONFIG_DIR/kibana.yml"
server.host: "0.0.0.0"
server.name: "kibana.cicd.local"
server.publicBaseUrl: "https://kibana.cicd.local:5601"

# SSL for Kibana UI
server.ssl.enabled: true
server.ssl.certificate: "/usr/share/kibana/config/certs/kibana.crt"
server.ssl.key: "/usr/share/kibana/config/certs/kibana.key"
server.ssl.certificateAuthorities: ["/usr/share/kibana/config/certs/ca.pem"]

# Connection to Elasticsearch
elasticsearch.hosts: [ "https://elasticsearch.cicd.local:9200" ]
elasticsearch.ssl.certificateAuthorities: [ "/usr/share/kibana/config/certs/ca.pem" ]
elasticsearch.username: "kibana_system"
elasticsearch.password: "\${ELASTICSEARCH_PASSWORD}"

# Persistence & Encryption
xpack.security.encryptionKey: "\${XPACK_SECURITY_ENCRYPTIONKEY}"
xpack.encryptedSavedObjects.encryptionKey: "\${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY}"
xpack.reporting.encryptionKey: "\${XPACK_REPORTING_ENCRYPTIONKEY}"

# Air-Gap Silence
telemetry.enabled: false
telemetry.optIn: false
newsfeed.enabled: false
map.includeElasticMapsService: false
xpack.fleet.enabled: false
xpack.apm.enabled: false
xpack.ml.enabled: false

# Pre-configured "Nervous System" Connector
xpack.actions.preconfigured:
  mattermost-webhook:
    name: "Mattermost CI/CD Channel"
    actionTypeId: .webhook
    config:
      url: "https://mattermost.cicd.local:8065/hooks/YOUR_HOOK_ID_HERE"
      method: post
      hasAuth: false
EOF

# C. Filebeat Configuration
cat << EOF > "$FILEBEAT_CONFIG_DIR/filebeat.yml"
filebeat.inputs:
  # 1. Jenkins (Java Logs)
  - type: filestream
    id: jenkins-logs
    paths:
      - /host_volumes/jenkins-home/_data/logs/jenkins.log
    fields: { service_name: "jenkins" }
    fields_under_root: true
    multiline.type: pattern
    multiline.pattern: '^\d{4}-\d{2}-\d{2}'
    multiline.negate: true
    multiline.match: after

  # 2. GitLab (Nginx Access/Error)
  - type: filestream
    id: gitlab-nginx
    paths:
      - /host_volumes/gitlab-logs/_data/nginx/*access.log
      - /host_volumes/gitlab-logs/_data/nginx/*error.log
    fields: { service_name: "gitlab-nginx" }
    fields_under_root: true

  # 3. SonarQube (Compute Engine)
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

  # 4. Mattermost (JSON)
  - type: filestream
    id: mattermost
    paths:
      - /host_volumes/mattermost-logs/_data/mattermost.log
    fields: { service_name: "mattermost" }
    fields_under_root: true

# Output Direct to Elasticsearch
output.elasticsearch:
  hosts: ["https://elasticsearch.cicd.local:9200"]
  pipeline: "cicd-logs"
  protocol: "https"
  ssl.certificate_authorities: ["/usr/share/filebeat/certs/ca.pem"]
  username: "elastic"
  password: "\${ELASTIC_PASSWORD}"

setup.ilm.enabled: false
setup.template.enabled: false
EOF

# --- 7. Generate Scoped Environment Files ---
echo "--- Phase 6: Generating Scoped Env Files ---"

# Elasticsearch Env
cat << EOF > "$ELK_BASE/elasticsearch/elasticsearch.env"
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
ES_JAVA_OPTS=-Xms1g -Xmx1g
EOF

# Kibana Env
cat << EOF > "$ELK_BASE/kibana/kibana.env"
ELASTICSEARCH_PASSWORD=$KIBANA_PASSWORD
XPACK_SECURITY_ENCRYPTIONKEY=$XPACK_SECURITY_ENCRYPTIONKEY
XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=$XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY
XPACK_REPORTING_ENCRYPTIONKEY=$XPACK_REPORTING_ENCRYPTIONKEY
EOF

# Filebeat Env
cat << EOF > "$ELK_BASE/filebeat/filebeat.env"
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
EOF

# Secure Env Files
chmod 600 "$ELK_BASE"/*/.*.env 2>/dev/null || true
chmod 600 "$ELK_BASE"/*/*.env 2>/dev/null || true

echo "✅ Setup Complete."
echo "   - Kernel configured (Idempotent)."
echo "   - Secrets generated."
echo "   - Configs written to $ELK_BASE"
echo "   - Certificates staged (UID 1000)."