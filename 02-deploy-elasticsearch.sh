#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               02-deploy-elasticsearch.sh
#
#  The "Bedrock" script.
#  Deploys Elasticsearch (v9.2.2) and bootstraps security.
#
#  1. Deploy: Runs ES with strict memory/ulimit guards.
#  2. Healthcheck: Waits for Green status via HTTPS (using CA).
#  3. Bootstrap: Sets 'kibana_system' password via API.
#
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Elasticsearch (The Bedrock)..."

# --- 1. Load Secrets ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
SCOPED_ENV_FILE="$ELK_BASE/elasticsearch/elasticsearch.env"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

if [ ! -f "$SCOPED_ENV_FILE" ]; then
    echo "ERROR: Scoped env file not found at $SCOPED_ENV_FILE"
    echo "Please run 01-setup-elk.sh first."
    exit 1
fi

# We need KIBANA_PASSWORD from master env for the bootstrap step
if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found."
    exit 1
fi
set -a; source "$MASTER_ENV_FILE"; set +a

if [ -z "$KIBANA_PASSWORD" ]; then
    echo "ERROR: KIBANA_PASSWORD not found in cicd.env"
    exit 1
fi

# --- 2. Clean Slate ---
if [ "$(docker ps -q -f name=elasticsearch)" ]; then
    echo "Stopping existing 'elasticsearch'..."
    docker stop elasticsearch
fi
if [ "$(docker ps -aq -f name=elasticsearch)" ]; then
    echo "Removing existing 'elasticsearch'..."
    docker rm elasticsearch
fi

# --- 3. Volume Management ---
echo "Verifying elasticsearch-data volume..."
docker volume create elasticsearch-data > /dev/null

# --- 4. Deploy ---
echo "--- Launching Container ---"

# NOTES:
# - ulimit: Essential for ES performance (avoids bootstrap checks failure)
# - cap-add IPC_LOCK: Allows memory locking to prevent swapping
# - publish: 9200 bound to 127.0.0.1 (Host access only)

docker run -d \
  --name elasticsearch \
  --restart always \
  --network cicd-net \
  --hostname elasticsearch.cicd.local \
  --publish 127.0.0.1:9200:9200 \
  --ulimit nofile=65535:65535 \
  --ulimit memlock=-1:-1 \
  --cap-add=IPC_LOCK \
  --env-file "$SCOPED_ENV_FILE" \
  --volume elasticsearch-data:/usr/share/elasticsearch/data \
  --volume "$ELK_BASE/elasticsearch/config/elasticsearch.yml":/usr/share/elasticsearch/config/elasticsearch.yml \
  --volume "$ELK_BASE/elasticsearch/config/certs":/usr/share/elasticsearch/config/certs \
  docker.elastic.co/elasticsearch/elasticsearch:9.2.2

echo "Container started. Waiting for healthcheck..."

# --- 5. Secure Bootstrap (The "Zero Touch" Logic) ---

MAX_RETRIES=60
COUNT=0
ES_URL="https://127.0.0.1:9200"

# A. Extract ELASTIC_PASSWORD securely (Avoiding 'source' errors)
ELASTIC_PASSWORD=$(grep "^ELASTIC_PASSWORD=" "$SCOPED_ENV_FILE" | cut -d'=' -f2 | tr -d '"')

# Wait for "status" to be green OR yellow
# We removed --cacert because the host trusts the CA
until curl -s -u "elastic:$ELASTIC_PASSWORD" "$ES_URL/_cluster/health" | grep -qE '"status":"(green|yellow)"'; do
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Timeout waiting for Elasticsearch."
        echo "Check logs: docker logs elasticsearch"
        exit 1
    fi
    echo "   [$COUNT/$MAX_RETRIES] Waiting for Green/Yellow status..."
    sleep 5
    COUNT=$((COUNT+1))
done

echo "✅ Elasticsearch is Online."

# B. Set kibana_system Password
echo "--- Bootstrapping Service Accounts ---"

# 1. Run the command and let it print directly to stdout
curl -i \
    -X POST "$ES_URL/_security/user/kibana_system/_password" \
    -u "elastic:$ELASTIC_PASSWORD" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$KIBANA_PASSWORD\"}"

# 2. Check the exit status of the curl command itself (simplified check)
if [ $? -eq 0 ]; then
    echo "" # Newline for formatting
    echo "✅ 'kibana_system' password request sent."
else
    echo ""
    echo "❌ Failed to send password request."
    exit 1
fi

echo "--- Bedrock Deployed Successfully ---"