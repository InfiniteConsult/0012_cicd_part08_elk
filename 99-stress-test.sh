#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           99-stress-test.sh
#
#  Generates 1000 System Errors and 1000 Access Events
#  to stress-test ELK dashboards.
# -----------------------------------------------------------

set -e

echo "🔥 Starting ELK 'Nuclear' Stress Test..."
echo "---------------------------------"

# 1. Generate 1000 System Events (Traffic Light -> RED)
echo "1. Injecting 1000 System Errors & Warnings..."
for i in {1..1000}; do
    logger -p syslog.err "CICD-STRESS-TEST: Critical Database Failure #$i"
    logger -p syslog.warning "CICD-STRESS-TEST: Memory Threshold Exceeded #$i"
    
    # Progress bar effect (print a dot every 50 events)
    ((i % 50 == 0)) && echo -n "."
done
echo " Done."

echo "---------------------------------"

# 2. Generate 1000 Access Events (Intruder Alert -> SPIKE)
# We target Port 10300 (GitLab HTTPS).
# Expect 302 (Redirect to Login) or 401/403 depending on the endpoint.
echo "2. Simulating 1000 Access Attempts on GitLab (Port 10300)..."
for i in {1..1000}; do
    # Hit the protected admin endpoint on the correct mapped port
    curl -s -o /dev/null "https://gitlab.cicd.local:10300/admin"
    
    ((i % 50 == 0)) && echo -n "."
done
echo " Done."

echo "---------------------------------"
echo "🎉 Stress Test Complete."
echo "   Go to Kibana -> Refresh Dashboard (Last 15 Minutes)"
echo "   You should see a massive spike in '302' events."