#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               03-deploy-kibana.sh
#
#  The "Interface" script.
#  Deploys Kibana (v9.2.2) with full persistence and security.
#
#  1. Secrets: Injects Encryption Keys to ensure session persistence.
#  2. Deploy: Runs Kibana binding to host 127.0.0.1.
#  3. Healthcheck: Waits for API status 'green' and prints progress.
#
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Kibana (The Interface)..."

# --- 1. Load Secrets ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
# We use the scoped env file for non-secret vars, but master for keys
SCOPED_ENV_FILE="$ELK_BASE/kibana/kibana.env"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

if [ ! -f "$SCOPED_ENV_FILE" ]; then
    echo "ERROR: Scoped env file not found at $SCOPED_ENV_FILE"
    echo "Please run 01-setup-elk.sh first."
    exit 1
fi

if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found."
    exit 1
fi

# Load Encryption Keys and Password
set -a; source "$MASTER_ENV_FILE"; set +a

# Validation
REQUIRED_VARS=("KIBANA_PASSWORD" "XPACK_SECURITY_ENCRYPTIONKEY" "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY" "XPACK_REPORTING_ENCRYPTIONKEY")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $var not found in cicd.env"
        exit 1
    fi
done

# --- 2. Clean Slate ---
if [ "$(docker ps -q -f name=kibana)" ]; then
    echo "Stopping existing 'kibana'..."
    docker stop kibana
fi
if [ "$(docker ps -aq -f name=kibana)" ]; then
    echo "Removing existing 'kibana'..."
    docker rm kibana
fi

# --- 3. Deploy ---
echo "--- Launching Container ---"

# NOTES:
# - ELASTICSEARCH_PASSWORD: Used by 'kibana_system' service account
# - XPACK_..._ENCRYPTIONKEY: Critical for session/alert persistence
# - server.publicBaseUrl: Configured in kibana.yml via 01-setup script

docker run -d \
  --name kibana \
  --restart always \
  --network cicd-net \
  --hostname kibana.cicd.local \
  --publish 127.0.0.1:5601:5601 \
  --env "ELASTICSEARCH_PASSWORD=$KIBANA_PASSWORD" \
  --env "XPACK_SECURITY_ENCRYPTIONKEY=$XPACK_SECURITY_ENCRYPTIONKEY" \
  --env "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=$XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY" \
  --env "XPACK_REPORTING_ENCRYPTIONKEY=$XPACK_REPORTING_ENCRYPTIONKEY" \
  --volume "$ELK_BASE/kibana/config/kibana.yml":/usr/share/kibana/config/kibana.yml \
  --volume "$ELK_BASE/kibana/config/certs":/usr/share/kibana/config/certs \
  docker.elastic.co/kibana/kibana:9.2.2

echo "Container started. Waiting for API healthcheck..."

# --- 4. Healthcheck Loop ---
KIBANA_URL="https://127.0.0.1:5601"

MAX_RETRIES=60
COUNT=0

# Loop until we see "level":"available"
# We trust the Root CA on the host, so no --cacert needed

while true; do
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Timeout waiting for Kibana."
        echo "Check logs: docker logs kibana"
        exit 1
    fi

    # Capture output. -sS silent but show errors.
    STATUS_OUTPUT=$(curl -sS "$KIBANA_URL/api/status" || true)

    # Check if we got a valid JSON response containing "level":"available"
    if echo "$STATUS_OUTPUT" | grep -q '"level":"available"'; then
        echo "   [$COUNT/$MAX_RETRIES] Status: AVAILABLE"
        break
    else
        # Try to extract the status level for better feedback (if JSON exists)
        # Grep matching "level":"something"
        CURRENT_LEVEL=$(echo "$STATUS_OUTPUT" | grep -o '"level":"[^"]*"' | head -n1 || echo "unreachable")

        # If output is empty or not JSON, define as booting/unreachable
        if [ -z "$CURRENT_LEVEL" ] || [ "$CURRENT_LEVEL" == "unreachable" ]; then
             echo "   [$COUNT/$MAX_RETRIES] Status: Connecting..."
        else
             echo "   [$COUNT/$MAX_RETRIES] Status: $CURRENT_LEVEL"
        fi
    fi

    sleep 5
    COUNT=$((COUNT+1))
done

echo "✅ Kibana is Green and Available."
echo "   Access at: https://kibana.cicd.local:5601"