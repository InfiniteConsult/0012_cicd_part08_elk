#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               01-setup-elk.sh
#
#  The "Architect" script for the ELK Stack.
#
#  1. Kernel: Enforces vm.max_map_count=262144 (Idempotent).
#  2. Secrets: Generates Passwords & Encryption Keys.
#  3. Certs: Stages keys using sudo; sets container ownership (1000:0).
#  4. Configs: Generates elasticsearch.yml, kibana.yml, filebeat.yml.
#  5. Permissions: Fixes ownership of env files for the host user.
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

# --- 2. Host Kernel Tuning (Idempotent) ---
echo "--- Phase 1: Kernel Tuning ---"
REQUIRED_MAP_COUNT=262144
SYSCTL_CONF="/etc/sysctl.conf"

# A. Runtime Check (Fixed sudo)
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
    STORED_VAL=$(grep "^\s*vm.max_map_count" "$SYSCTL_CONF" | awk -F= '{print $2}' | tr -d '[:space:]')
    if [[ "$STORED_VAL" -lt "$REQUIRED_MAP_COUNT" ]]; then
        echo "Stored value ($STORED_VAL) is too low. Updating config in-place..."
        sudo sed -i "s/^\s*vm.max_map_count.*/vm.max_map_count=$REQUIRED_MAP_COUNT/" "$SYSCTL_CONF"
    else
        echo "Stored configuration is sufficient ($STORED_VAL)."
    fi
else
    echo "Value missing. Appending to config..."
    echo "vm.max_map_count=$REQUIRED_MAP_COUNT" | sudo tee -a "$SYSCTL_CONF" > /dev/null
fi

# --- 3. Directory Setup ---
echo "--- Phase 2: Directory Scaffolding ---"
sudo mkdir -p "$ES_CONFIG_DIR/certs"
sudo mkdir -p "$KIBANA_CONFIG_DIR/certs"
sudo mkdir -p "$FILEBEAT_CONFIG_DIR/certs"

# --- 4. Secrets Management ---
echo "--- Phase 3: Secrets Generation ---"

if [ ! -f "$MASTER_ENV_FILE" ]; then touch "$MASTER_ENV_FILE"; fi

key_exists() { grep -q "^$1=" "$MASTER_ENV_FILE"; }
generate_secret() { openssl rand -hex 32; }
generate_password() { openssl rand -hex 16; }

update_env=false

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

# 4b. Kibana Encryption Keys
if ! key_exists "XPACK_SECURITY_ENCRYPTIONKEY"; then
    echo "Generating Persistence Keys..."
    echo "XPACK_SECURITY_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    echo "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    echo "XPACK_REPORTING_ENCRYPTIONKEY=\"$(generate_secret)\"" >> "$MASTER_ENV_FILE"
    update_env=true
fi

if [ "$update_env" = true ]; then echo "Secrets updated in cicd.env"; else echo "Secrets already exist."; fi

set -a; source "$MASTER_ENV_FILE"; set +a

# --- 5. Certificate Staging ---
echo "--- Phase 4: Staging Certificates ---"

# Validate existence
if [ ! -f "$SRC_ES_CRT" ] || [ ! -f "$SRC_ES_KEY" ]; then
    echo "ERROR: Elasticsearch certificates not found."
    exit 1
fi
if [ ! -f "$SRC_KIB_CRT" ] || [ ! -f "$SRC_KIB_KEY" ]; then
    echo "ERROR: Kibana certificates not found."
    exit 1
fi

# Use sudo cp to overwrite potential root-owned files
echo "Staging Elasticsearch certificates..."
sudo cp "$SRC_ES_CRT" "$ES_CONFIG_DIR/certs/elasticsearch.crt"
sudo cp "$SRC_ES_KEY" "$ES_CONFIG_DIR/certs/elasticsearch.key"
sudo cp "$SRC_CA_CRT" "$ES_CONFIG_DIR/certs/ca.pem"

echo "Staging Kibana certificates..."
sudo cp "$SRC_KIB_CRT" "$KIBANA_CONFIG_DIR/certs/kibana.crt"
sudo cp "$SRC_KIB_KEY" "$KIBANA_CONFIG_DIR/certs/kibana.key"
sudo cp "$SRC_CA_CRT"  "$KIBANA_CONFIG_DIR/certs/ca.pem"

echo "Staging Filebeat CA..."
sudo cp "$SRC_CA_CRT"  "$FILEBEAT_CONFIG_DIR/certs/ca.pem"

# D. Permissions
echo "Fixing permissions..."
# ES and Kibana run as UID 1000. We give group ownership to root (0).
sudo chown -R 1000:0 "$ES_CONFIG_DIR/certs"
sudo chown -R 1000:0 "$KIBANA_CONFIG_DIR/certs"
# Filebeat runs as root
sudo chown -R 0:0    "$FILEBEAT_CONFIG_DIR/certs"

# Secure Keys (600), Public Certs (644)
sudo chmod 600 "$ES_CONFIG_DIR/certs/"*.key
sudo chmod 600 "$KIBANA_CONFIG_DIR/certs/"*.key
sudo chmod 644 "$ES_CONFIG_DIR/certs/"*.crt
sudo chmod 644 "$KIBANA_CONFIG_DIR/certs/"*.crt

# --- 6. Configuration Generation ---
echo "--- Phase 5: Generating Config Files ---"

# A. Elasticsearch Configuration
sudo bash -c "cat << EOF > \"$ES_CONFIG_DIR/elasticsearch.yml\"
cluster.name: \"cicd-elk\"
node.name: \"elasticsearch.cicd.local\"
network.host: 0.0.0.0
discovery.type: single-node

path.data: /usr/share/elasticsearch/data
path.logs: /usr/share/elasticsearch/logs

xpack.security.enabled: true

xpack.security.http.ssl:
  enabled: true
  key: /usr/share/elasticsearch/config/certs/elasticsearch.key
  certificate: /usr/share/elasticsearch/config/certs/elasticsearch.crt
  certificate_authorities: [ \"/usr/share/elasticsearch/config/certs/ca.pem\" ]

xpack.security.transport.ssl:
  enabled: true
  key: /usr/share/elasticsearch/config/certs/elasticsearch.key
  certificate: /usr/share/elasticsearch/config/certs/elasticsearch.crt
  certificate_authorities: [ \"/usr/share/elasticsearch/config/certs/ca.pem\" ]

ingest.geoip.downloader.enabled: false
EOF"

# B. Kibana Configuration
# We use \${VAR} to tell Docker to replace this at runtime from the env file
sudo bash -c "cat << EOF > \"$KIBANA_CONFIG_DIR/kibana.yml\"
server.host: \"0.0.0.0\"
server.name: \"kibana.cicd.local\"
server.publicBaseUrl: \"https://kibana.cicd.local:5601\"

server.ssl.enabled: true
server.ssl.certificate: \"/usr/share/kibana/config/certs/kibana.crt\"
server.ssl.key: \"/usr/share/kibana/config/certs/kibana.key\"
server.ssl.certificateAuthorities: [\"/usr/share/kibana/config/certs/ca.pem\"]

elasticsearch.hosts: [ \"https://elasticsearch.cicd.local:9200\" ]
elasticsearch.ssl.certificateAuthorities: [ \"/usr/share/kibana/config/certs/ca.pem\" ]
elasticsearch.username: \"kibana_system\"
elasticsearch.password: \"\${ELASTICSEARCH_PASSWORD}\"

xpack.security.encryptionKey: \"\${XPACK_SECURITY_ENCRYPTIONKEY}\"
xpack.encryptedSavedObjects.encryptionKey: \"\${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY}\"
xpack.reporting.encryptionKey: \"\${XPACK_REPORTING_ENCRYPTIONKEY}\"

telemetry.enabled: false
telemetry.optIn: false
newsfeed.enabled: false
map.includeElasticMapsService: false
xpack.fleet.enabled: false
xpack.apm.enabled: false

xpack.actions.preconfigured:
  mattermost-webhook:
    name: \"Mattermost CI/CD Channel\"
    actionTypeId: .webhook
    config:
      # Maps to the env var we inject in kibana.env
      url: \"\${MATTERMOST_WEBHOOK_URL}\"
      method: post
      hasAuth: false
EOF"

# C. Filebeat Configuration
sudo bash -c "cat << EOF > \"$FILEBEAT_CONFIG_DIR/filebeat.yml\"
filebeat.inputs:
  # 1. Jenkins
  - type: filestream
    id: jenkins-logs
    paths:
      - /host_volumes/jenkins-home/_data/logs/jenkins.log
    fields: { service_name: \"jenkins\" }
    fields_under_root: true
    multiline.type: pattern
    multiline.pattern: '^\d{4}-\d{2}-\d{2}'
    multiline.negate: true
    multiline.match: after

  # 2. GitLab Nginx
  - type: filestream
    id: gitlab-nginx
    paths:
      - /host_volumes/gitlab-logs/_data/nginx/*access.log
      - /host_volumes/gitlab-logs/_data/nginx/*error.log
    fields: { service_name: \"gitlab-nginx\" }
    fields_under_root: true

  # 3. SonarQube CE
  - type: filestream
    id: sonarqube-ce
    paths:
      - /host_volumes/sonarqube-logs/_data/ce.log
    fields: { service_name: \"sonarqube\" }
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
    fields: { service_name: \"mattermost\" }
    fields_under_root: true

  # 5. Artifactory
  - type: filestream
    id: artifactory
    paths:
      - /host_volumes/artifactory-data/_data/log/artifactory-service.log
      - /host_volumes/artifactory-data/_data/log/artifactory-request.log
      - /host_volumes/artifactory-data/_data/log/access-service.log
    fields: { service_name: \"artifactory\" }
    fields_under_root: true
    multiline.type: pattern
    multiline.pattern: '^\d{4}-\d{2}-\d{2}'
    multiline.negate: true
    multiline.match: after

  # 6. Host System Logs
  - type: filestream
    id: host-system
    paths:
      - /host_system_logs/syslog
      - /host_system_logs/auth.log
    fields: { service_name: \"system\" }
    fields_under_root: true

output.elasticsearch:
  hosts: [\"https://elasticsearch.cicd.local:9200\"]
  pipeline: \"cicd-logs\"
  protocol: \"https\"
  ssl.certificate_authorities: [\"/usr/share/filebeat/certs/ca.pem\"]
  username: \"elastic\"
  password: \"\${ELASTIC_PASSWORD}\"

setup.ilm.enabled: false
setup.template.enabled: false
EOF"

# --- 7. Generate Scoped Environment Files ---
echo "--- Phase 6: Generating Scoped Env Files ---"

# We use sudo tee to write, which creates root-owned files
cat << EOF | sudo tee "$ELK_BASE/elasticsearch/elasticsearch.env" > /dev/null
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
ES_JAVA_OPTS=-Xms1g -Xmx1g
EOF

cat << EOF | sudo tee "$ELK_BASE/kibana/kibana.env" > /dev/null
ELASTICSEARCH_PASSWORD=$KIBANA_PASSWORD
XPACK_SECURITY_ENCRYPTIONKEY=$XPACK_SECURITY_ENCRYPTIONKEY
XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=$XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY
XPACK_REPORTING_ENCRYPTIONKEY=$XPACK_REPORTING_ENCRYPTIONKEY
# NEW: Inject the webhook URL from master secrets
MATTERMOST_WEBHOOK_URL=$SONAR_MATTERMOST_WEBHOOK
EOF

cat << EOF | sudo tee "$ELK_BASE/filebeat/filebeat.env" > /dev/null
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
EOF

# --- 8. Permission Fix for Env Files ---
echo "Fixing ownership of environment files for current user..."
CURRENT_USER=$(id -u)
CURRENT_GROUP=$(id -g)

sudo chown "$CURRENT_USER":"$CURRENT_GROUP" "$ELK_BASE"/elasticsearch/elasticsearch.env
sudo chown "$CURRENT_USER":"$CURRENT_GROUP" "$ELK_BASE"/kibana/kibana.env
sudo chown "$CURRENT_USER":"$CURRENT_GROUP" "$ELK_BASE"/filebeat/filebeat.env

chmod 600 "$ELK_BASE"/*/*.env

echo "✅ Setup Complete."