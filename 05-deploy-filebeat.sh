#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               05-deploy-filebeat.sh (Final Fixed)
#
#  The "Collector" Script.
#  Deploys Filebeat (v9.2.2) to ship logs to Elasticsearch.
#
#  1. Mounts Host Docker Volumes (read app logs).
#  2. Mounts Host Journal (read system logs).
#  3. Mounts Data Volume (PERSIST REGISTRY).
#  4. Runs as ROOT to bypass host directory permissions.
#
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Filebeat (The Collector)..."

# --- 1. Load Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
SCOPED_ENV_FILE="$ELK_BASE/filebeat/filebeat.env"

if [ ! -f "$SCOPED_ENV_FILE" ]; then
    echo "ERROR: Scoped env file not found at $SCOPED_ENV_FILE"
    echo "Please run 01-setup-elk.sh first."
    exit 1
fi

# --- 2. Clean Slate ---
if [ "$(docker ps -q -f name=filebeat)" ]; then
    echo "Stopping existing 'filebeat'..."
    docker stop filebeat
fi
if [ "$(docker ps -aq -f name=filebeat)" ]; then
    echo "Removing existing 'filebeat'..."
    docker rm filebeat
fi

# --- 3. Volume Management (CRITICAL FIX) ---
# We must persist the registry so we don't re-ingest old logs on restart.
echo "Verifying filebeat-data volume..."
docker volume create filebeat-data > /dev/null

# --- 4. Deploy ---
echo "--- Launching Container ---"

# NOTES:
# - user root: Required to traverse /var/lib/docker and read Journal.
# - /var/log/journal: Required for native journald input.
# - /etc/machine-id: Required for journald reader to track host identity.

docker run -d \
  --name filebeat \
  --restart always \
  --network cicd-net \
  --user root \
  --env-file "$SCOPED_ENV_FILE" \
  --volume "$ELK_BASE/filebeat/config/filebeat.yml":/usr/share/filebeat/filebeat.yml:ro \
  --volume "$ELK_BASE/filebeat/config/certs":/usr/share/filebeat/certs:ro \
  --volume filebeat-data:/usr/share/filebeat/data \
  --volume /var/lib/docker/volumes:/host_volumes:ro \
  --volume /var/log/journal:/var/log/journal:ro \
  --volume /etc/machine-id:/etc/machine-id:ro \
  docker.elastic.co/beats/filebeat:9.2.2

echo "Container started. Verifying connection..."

# --- 5. Verification ---
MAX_RETRIES=15
COUNT=0
echo "Waiting for Filebeat to establish connection..."

while [ $COUNT -lt $MAX_RETRIES ]; do
    sleep 2
    # Check for successful connection message
    if docker logs filebeat 2>&1 | grep -q "Connection to backoff.*established"; then
        echo "✅ Filebeat successfully connected to Elasticsearch!"
        exit 0
    fi

    # Fail fast on Pipeline errors (common misconfiguration)
    if docker logs filebeat 2>&1 | grep -q "pipeline/cicd-logs.*missing"; then
        echo "❌ ERROR: Filebeat says the 'cicd-logs' pipeline is missing!"
        echo "   Did you run 04-setup-pipelines.sh?"
        exit 1
    fi

    # Fail fast on Certificate errors
    if docker logs filebeat 2>&1 | grep -q "x509: certificate signed by unknown authority"; then
        echo "❌ ERROR: SSL Certificate trust issue."
        echo "   Check that ca.pem is correctly mounted and generated."
        exit 1
    fi

    echo "   [$COUNT/$MAX_RETRIES] Connecting..."
    COUNT=$((COUNT+1))
done

echo "⚠️  Connection check timed out. Check logs manually:"
echo "   docker logs -f filebeat"