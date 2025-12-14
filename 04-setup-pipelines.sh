#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           04-setup-pipelines.sh (Final Fix)
#
#  Configures Elasticsearch Ingest Pipelines.
#  Refined based on actual log samples.
# -----------------------------------------------------------

set -e
echo "🚀 Configuring Elasticsearch Ingest Pipelines..."

# --- 1. Load Secrets ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
source "$ELK_BASE/filebeat/filebeat.env"

# --- 2. Define the Pipeline JSON ---
# CRITICAL: We use 'EOF' (quoted) to prevent Bash from stripping regex backslashes.

PIPELINE_JSON=$(cat <<'EOF'
{
  "description": "CICD Stack Log Parsing Pipeline",
  "processors": [
    {
      "set": {
        "field": "event.original",
        "value": "{{message}}",
        "ignore_empty_value": true
      }
    },
    {
      "grok": {
        "field": "message",
        "patterns": [
          "%{IPORHOST:client.ip} - %{DATA:user.name} \\[%{HTTPDATE:timestamp}\\] \"%{WORD:http.request.method} %{DATA:url.path} HTTP/%{NUMBER:http.version}\" %{NUMBER:http.response.status_code:long} %{NUMBER:http.response.body.bytes:long} \"%{DATA:http.request.referrer}\" \"%{DATA:user_agent.original}\""
        ],
        "if": "ctx.service_name == 'gitlab-nginx'",
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "field": "message",
        "patterns": [
          "%{YEAR:year}\\.%{MONTHNUM:month}\\.%{MONTHDAY:day} %{TIME:time} %{LOGLEVEL:log.level}\\s+%{GREEDYDATA:message}"
        ],
        "if": "ctx.service_name == 'sonarqube'",
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "script": {
        "lang": "painless",
        "source": "ctx.timestamp = ctx.year + '-' + ctx.month + '-' + ctx.day + 'T' + ctx.time + 'Z'",
        "if": "ctx.service_name == 'sonarqube' && ctx.year != null"
      }
    },
    {
      "json": {
        "field": "message",
        "target_field": "mattermost",
        "if": "ctx.service_name == 'mattermost'",
        "ignore_failure": true
      }
    },
    {
      "set": {
        "field": "timestamp",
        "value": "{{mattermost.timestamp}}",
        "if": "ctx.service_name == 'mattermost' && ctx.mattermost?.timestamp != null"
      }
    },
    {
      "set": {
        "field": "log.level",
        "value": "{{mattermost.level}}",
        "if": "ctx.service_name == 'mattermost' && ctx.mattermost?.level != null"
      }
    },
    {
      "grok": {
        "field": "message",
        "patterns": [
          "%{TIMESTAMP_ISO8601:timestamp} \\[%{DATA:service_type}\\s*\\] \\[%{LOGLEVEL:log.level}\\s*\\] \\[%{DATA:trace_id}\\] \\[%{DATA:class}:%{NUMBER:line}\\] (?>\\[%{DATA:thread_info}\\] )?- %{GREEDYDATA:message}",
          "%{TIMESTAMP_ISO8601:timestamp}\\|%{DATA:trace_id}\\|%{IP:client.ip}\\|%{DATA:user.name}\\|%{WORD:http.request.method}\\|%{DATA:url.path}\\|%{NUMBER:http.response.status_code:long}\\|.*"
        ],
        "if": "ctx.service_name == 'artifactory'",
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "date": {
        "field": "timestamp",
        "formats": [
          "ISO8601",
          "dd/MMM/yyyy:HH:mm:ss Z",
          "yyyy-MM-dd HH:mm:ss.SSS",
          "yyyy-MM-dd HH:mm:ss.SSS Z",
          "yyyy-MM-dd HH:mm:ss Z",
          "MMM  d HH:mm:ss",
          "MMM dd HH:mm:ss"
        ],
        "target_field": "@timestamp",
        "ignore_failure": true
      }
    },
    {
      "remove": {
        "field": ["timestamp", "year", "month", "day", "time", "mattermost"],
        "ignore_missing": true
      }
    }
  ],
  "on_failure": [
    {
      "set": {
        "field": "error.message",
        "value": "Pipeline failed: {{ _ingest.on_failure_message }}"
      }
    }
  ]
}
EOF
)

# --- 3. Upload to Elasticsearch ---
echo "--- Uploading 'cicd-logs' Pipeline ---"

# We use -w to capture the HTTP status code at the end
RESPONSE=$(curl -s -k -w "\n%{http_code}" -X PUT "https://127.0.0.1:9200/_ingest/pipeline/cicd-logs" \
  -u "elastic:$ELASTIC_PASSWORD" \
  -H "Content-Type: application/json" \
  -d "$PIPELINE_JSON")

# Extract Body and Status Code
HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo "✅ Pipeline updated successfully (HTTP 200)."
  echo "Response: $HTTP_BODY"
else
  echo "❌ Error uploading pipeline (HTTP $HTTP_STATUS)."
  echo "Elasticsearch Response:"
  echo "$HTTP_BODY"
  exit 1
fi