#!/bin/bash
# =============================================================================
# Clear Kafka Topic Messages via Kafka UI REST API
# =============================================================================

set -e

KAFKA_UI_URL="http://localhost:8088"
CLUSTER_NAME="local"

echo "=== Clearing messages from Kafka topics via Kafka UI ==="

# List of topics to clear
TOPICS=(
  "request-events.us-east"
  "request-events.us-central"
  "request-events.us-west"
)

# Clear messages for each topic using Kafka UI REST API
for topic in "${TOPICS[@]}"; do
  echo "Clearing topic: $topic"

  # Kafka UI delete messages endpoint
  response=$(curl -s -X DELETE \
    "${KAFKA_UI_URL}/api/clusters/${CLUSTER_NAME}/topics/${topic}/messages" \
    -w "\n%{http_code}" 2>&1)

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" == "200" ] || [ "$http_code" == "204" ]; then
    echo "  ✓ Successfully cleared messages"
  else
    echo "  ✗ Failed (HTTP $http_code)"
    echo "  Response: $(echo "$response" | head -n-1)"
  fi
done

echo ""
echo "=== Kafka topic cleanup complete ==="
echo ""
echo "Verify at: ${KAFKA_UI_URL}/ui/clusters/${CLUSTER_NAME}/all-topics"
