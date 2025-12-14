#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               03-deploy-kibana.sh
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Kibana (The Interface)..."

# --- 1. Load Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
SCOPED_ENV_FILE="$ELK_BASE/kibana/kibana.env"

# --- 2. Validation ---
if [ ! -f "$SCOPED_ENV_FILE" ]; then
    echo "ERROR: Scoped env file not found at $SCOPED_ENV_FILE"
    echo "Please run 01-setup-elk.sh first."
    exit 1
fi

# --- 3. Clean Slate ---
if [ "$(docker ps -q -f name=kibana)" ]; then
    echo "Stopping existing 'kibana'..."
    docker stop kibana
fi
if [ "$(docker ps -aq -f name=kibana)" ]; then
    echo "Removing existing 'kibana'..."
    docker rm kibana
fi

# --- 4. Deploy ---
echo "--- Launching Container ---"

# FIX: We rely fully on the env file now.
# It contains: ELASTICSEARCH_PASSWORD, XPACK Keys, and MATTERMOST_WEBHOOK_URL

docker run -d \
  --name kibana \
  --restart always \
  --network cicd-net \
  --hostname kibana.cicd.local \
  --publish 127.0.0.1:5601:5601 \
  --env-file "$SCOPED_ENV_FILE" \
  --volume "$ELK_BASE/kibana/config/kibana.yml":/usr/share/kibana/config/kibana.yml:ro \
  --volume "$ELK_BASE/kibana/config/certs":/usr/share/kibana/config/certs:ro \
  docker.elastic.co/kibana/kibana:9.2.2

echo "Container started. Waiting for API healthcheck..."

# --- 5. Healthcheck Loop ---
KIBANA_URL="https://127.0.0.1:5601"
MAX_RETRIES=60
COUNT=0

while true; do
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Timeout waiting for Kibana."
        echo "Check logs: docker logs kibana"
        exit 1
    fi

    STATUS_OUTPUT=$(curl -sS "$KIBANA_URL/api/status" || true)

    if echo "$STATUS_OUTPUT" | grep -q '"level":"available"'; then
        echo "   [$COUNT/$MAX_RETRIES] Status: AVAILABLE"
        break
    else
        CURRENT_LEVEL=$(echo "$STATUS_OUTPUT" | grep -o '"level":"[^"]*"' | head -n1 || echo "unreachable")
        echo "   [$COUNT/$MAX_RETRIES] Status: ${CURRENT_LEVEL:-unreachable}"
    fi

    sleep 5
    COUNT=$((COUNT+1))
done

echo "✅ Kibana is Green and Available."
echo "   Access at: https://kibana.cicd.local:5601"