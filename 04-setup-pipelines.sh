#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               04-setup-pipelines.sh
#
#  The "Brain Surgery" Script.
#  Installs the Ingest Pipeline to structure our logs.
#
#  1. Connects to Elasticsearch (using Bedrock credentials).
#  2. Defines the "cicd-logs" pipeline with conditional logic.
#  3. Handles Nginx, Java, JSON, and Syslog formats.
#
# -----------------------------------------------------------

set -e
echo "🚀 Configuring Elasticsearch Ingest Pipelines..."

# --- 1. Load Secrets ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
SCOPED_ENV_FILE="$ELK_BASE/elasticsearch/elasticsearch.env"

if [ ! -f "$SCOPED_ENV_FILE" ]; then
    echo "ERROR: Scoped env file not found."
    exit 1
fi

# Securely Extract Password
ELASTIC_PASSWORD=$(grep "^ELASTIC_PASSWORD=" "$SCOPED_ENV_FILE" | cut -d'=' -f2 | tr -d '"')
ES_URL="https://127.0.0.1:9200"

# --- 2. Define the Pipeline JSON ---
# Note: We use \u0027 for single quotes inside the JSON string to avoid Bash conflicts
PIPELINE_BODY='{
  "description": "CICD Stack Router: Parses Nginx, Java, JSON, and System logs based on service_name",
  "processors": [
    {
      "rename": {
        "field": "message",
        "target_field": "event.original",
        "ignore_missing": true,
        "description": "1. Backup the raw message to event.original"
      }
    },
    {
      "grok": {
        "if": "ctx.service_name == \u0027gitlab-nginx\u0027",
        "field": "event.original",
        "patterns": [
          "%{IPORHOST:client.ip} - %{DATA:user.name} \\[%{HTTPDATE:temp_timestamp}\\] \"%{WORD:http.request.method} %{DATA:url.path} HTTP/%{NUMBER:http.version}\" %{NUMBER:http.response.status_code:long} %{NUMBER:http.response.body.bytes:long} \"%{DATA:http.request.referrer}\" \"%{DATA:user_agent.original}\""
        ],
        "description": "2a. Parse Nginx Access Logs"
      }
    },
    {
      "date": {
        "if": "ctx.service_name == \u0027gitlab-nginx\u0027",
        "field": "temp_timestamp",
        "formats": ["dd/MMM/yyyy:HH:mm:ss Z"],
        "target_field": "@timestamp",
        "description": "2b. Fix Nginx Timestamp"
      }
    },
    {
      "json": {
        "if": "ctx.service_name == \u0027mattermost\u0027",
        "field": "event.original",
        "add_to_root": true,
        "description": "3. Expand Mattermost JSON to root"
      }
    },
    {
      "grok": {
        "if": "ctx.service_name == \u0027jenkins\u0027",
        "field": "event.original",
        "patterns": [
          "%{TIMESTAMP_ISO8601:temp_timestamp} \\[%{DATA:jenkins.node_id}\\] %{LOGLEVEL:log.level} %{JAVACLASS:jenkins.class}: %{GREEDYDATA:message}"
        ],
        "description": "4a. Parse Jenkins Java Logs"
      }
    },
    {
      "date": {
        "if": "ctx.service_name == \u0027jenkins\u0027",
        "field": "temp_timestamp",
        "formats": ["ISO8601"],
        "target_field": "@timestamp",
        "description": "4b. Fix Jenkins Timestamp"
      }
    },
    {
      "grok": {
        "if": "ctx.service_name == \u0027sonarqube\u0027 || ctx.service_name == \u0027artifactory\u0027",
        "field": "event.original",
        "patterns": [
          "(?<temp_timestamp>%{YEAR}\\.%{MONTHNUM}\\.%{MONTHDAY} %{TIME}) \\[%{LOGLEVEL:log.level}\\] %{GREEDYDATA:message}"
        ],
        "description": "5a. Parse Generic Java Logs (Sonar/Artifactory)"
      }
    },
    {
      "date": {
        "if": "ctx.service_name == \u0027sonarqube\u0027 || ctx.service_name == \u0027artifactory\u0027",
        "field": "temp_timestamp",
        "formats": ["yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm:ss.SSS"],
        "target_field": "@timestamp",
        "description": "5b. Fix Java App Timestamps"
      }
    },
    {
      "grok": {
        "if": "ctx.service_name == \u0027system\u0027",
        "field": "event.original",
        "patterns": [
          "%{SYSLOGTIMESTAMP:temp_timestamp} %{SYSLOGHOST:host.hostname} %{DATA:process.name}(?:\\[%{POSINT:process.pid:long}\\])?: %{GREEDYDATA:message}"
        ],
        "description": "6a. Parse System Syslogs"
      }
    },
    {
      "date": {
        "if": "ctx.service_name == \u0027system\u0027",
        "field": "temp_timestamp",
        "formats": ["MMM  d HH:mm:ss", "MMM dd HH:mm:ss"],
        "target_field": "@timestamp",
        "description": "6b. Fix Syslog Timestamps"
      }
    },
    {
      "remove": {
        "field": ["temp_timestamp"],
        "ignore_missing": true,
        "description": "7. Clean up temporary fields"
      }
    }
  ],
  "on_failure": [
    {
      "set": {
        "field": "error.message",
        "value": "Pipeline processing failed: {{ _ingest.on_failure_message }}"
      }
    }
  ]
}'

# --- 3. Push the Pipeline ---
echo "--- Uploading 'cicd-logs' Pipeline ---"

# Use curl to send PUT request, capturing body and status code separately
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X PUT "$ES_URL/_ingest/pipeline/cicd-logs" \
  -u "elastic:$ELASTIC_PASSWORD" \
  -H "Content-Type: application/json" \
  -d "$PIPELINE_BODY")

# Extract Status Code (Last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

# Extract Body (All lines except the last)
HTTP_BODY=$(echo "$RESPONSE" | sed '$d')

echo "API Response: $HTTP_BODY"

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "✅ Pipeline 'cicd-logs' installed successfully."
else
    echo "❌ Failed to install pipeline. HTTP Code: $HTTP_CODE"
    exit 1
fi

echo "--- Pipeline Setup Complete ---"