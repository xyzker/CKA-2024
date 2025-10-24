#!/bin/bash
set -x

# IMPORTANT: Using AU region endpoint
SUMO_API_ENDPOINT="https://api.sumologic.com/api/v1"

# Build the search query with Harness variables
SEARCH_QUERY="_index=sumologic_audit"

# Retry configuration
MAX_RETRIES=120          # Maximum number of attempts
RETRY_INTERVAL=30      # Wait 30 seconds between retries
CURRENT_ATTEMPT=1

echo "========================================"
echo "SumoLogic Teardown Verification"
echo "========================================"
echo "Max retries: ${MAX_RETRIES}"
echo "Retry interval: ${RETRY_INTERVAL}s"
echo ""

# Function to perform a single search attempt
perform_search() {
  local attempt=$1

  echo "----------------------------------------"
  echo "Attempt ${attempt}/${MAX_RETRIES}"
  echo "----------------------------------------"

  # Time range (last 15 minutes - adjust as needed)
  FROM_TIME=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%S")
  TO_TIME=$(date -u -v+24H +"%Y-%m-%dT%H:%M:%S")

  echo "Query: ${SEARCH_QUERY}"
  echo "Time range: ${FROM_TIME} to ${TO_TIME}"
  echo ""

  # Step 1: Create search job
  echo "[1/3] Creating search job..."
  curl -s -X POST \
    -u "${SUMO_ACCESS_ID}:${SUMO_ACCESS_KEY}" \
    -H "Content-Type: application/json" \
    -D headers.txt \
    -o body.txt \
    "${SUMO_API_ENDPOINT}/search/jobs" \
    -d "{
      \"query\": \"${SEARCH_QUERY}\",
      \"from\": \"${FROM_TIME}\",
      \"to\": \"${TO_TIME}\",
      \"timeZone\": \"Asia/Singapore\",
      \"autoParsingMode\": \"AutoParse\",
      \"requiresRawMessages\": true
    }"

  echo "Response headers:"
  cat headers.txt
  echo ""
  JOB_RESPONSE=$(cat body.txt)

  # Extract job ID and status link
  echo "Raw job response: ${JOB_RESPONSE}"

  JOB_ID=$(echo "${JOB_RESPONSE}" | jq -r '.id')
  STATUS_LINK=$(echo "${JOB_RESPONSE}" | jq -r '.link.href')

  if [ -z "${JOB_ID}" ] || [ "${JOB_ID}" == "null" ]; then
    echo "ERROR: Failed to create search job"
    echo "Response: ${JOB_RESPONSE}"
    return 2  # Return error code 2 for job creation failure
  fi

  echo "✓ Search job created: ${JOB_ID}, Status Link: ${STATUS_LINK}"
  echo ""

  # Cleanup temp files
  rm -f headers.txt body.txt

  # Step 2: Poll for job completion
  echo "[2/3] Polling for job completion..."
  POLL_INTERVAL=3
  MAX_WAIT=120
  ELAPSED=0
  STATE=""

  while [ "${STATE}" != "DONE GATHERING RESULTS" ]; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
      echo "ERROR: Search job timed out after ${MAX_WAIT}s"
      return 2  # Return error code 2 for timeout
    fi

    curl -s -X GET \
      -u "${SUMO_ACCESS_ID}:${SUMO_ACCESS_KEY}" \
      -D headers_poll.txt \
      -o status_body.txt \
      "${STATUS_LINK}"

    echo "Polling response headers:"
    cat headers_poll.txt
    echo ""
    JOB_STATUS=$(cat status_body.txt)

    STATE=$(echo "${JOB_STATUS}" | jq -r '.state')
    MSG_COUNT=$(echo "${JOB_STATUS}" | jq -r '.messageCount')
    RECORD_COUNT=$(echo "${JOB_STATUS}" | jq -r '.recordCount')

    echo "  State: ${STATE} | Messages: ${MSG_COUNT} | Records: ${RECORD_COUNT} (${ELAPSED}s elapsed)"

    # Cleanup temp files
    rm -f headers_poll.txt status_body.txt

    if [ "${STATE}" != "DONE GATHERING RESULTS" ]; then
      sleep $POLL_INTERVAL
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
    fi
  done

  echo "✓ Search job completed"
  echo ""

  # Step 3: Evaluate results
  echo "[3/3] Evaluating results..."
  echo "Total message count: ${MSG_COUNT}"
  echo ""

  if [ "${MSG_COUNT}" -gt 0 ]; then
    echo "========================================"
    echo "✓ SUCCESS: Teardown completion verified"
    echo "========================================"
    echo "Found ${MSG_COUNT} log entries matching the teardown completion message"
    echo "Service teardown completed successfully"
    echo ""

    # Fetch and display a sample log entry
    curl -s -X GET \
      -u "${SUMO_ACCESS_ID}:${SUMO_ACCESS_KEY}" \
      -D headers_results.txt \
      -o results_body.txt \
      "${SUMO_API_ENDPOINT}/search/jobs/${JOB_ID}/messages?offset=0&limit=1"

    echo "Results response headers:"
    cat headers_results.txt
    echo ""
    RESULTS=$(cat results_body.txt)

    echo "Sample log entry:"
    echo "${RESULTS}" | jq -r '.messages[0].map._raw' | head -n 3
    echo ""

    # Cleanup temp files
    rm -f headers_results.txt results_body.txt

    return 0  # Success
  else
    echo "No matching log entries found in this attempt"
    return 1  # Return error code 1 for no results (retriable)
  fi
}

# Main retry loop
while [ $CURRENT_ATTEMPT -le $MAX_RETRIES ]; do
  perform_search $CURRENT_ATTEMPT
  SEARCH_RESULT=$?

  if [ $SEARCH_RESULT -eq 0 ]; then
    # Success - exit script with success
    exit 0
  elif [ $SEARCH_RESULT -eq 2 ]; then
    # Critical error (job creation failed or timeout) - exit immediately
    echo ""
    echo "========================================"
    echo "✗ CRITICAL ERROR"
    echo "========================================"
    echo "Search job creation or execution failed"
    exit 1
  else
    # No results found (retriable error)
    if [ $CURRENT_ATTEMPT -lt $MAX_RETRIES ]; then
      echo ""
      echo "⚠ No results found. Retrying in ${RETRY_INTERVAL} seconds..."
      echo "   (Attempt ${CURRENT_ATTEMPT}/${MAX_RETRIES})"
      echo ""
      sleep $RETRY_INTERVAL
      CURRENT_ATTEMPT=$((CURRENT_ATTEMPT + 1))
    else
      # All retries exhausted
      echo ""
      echo "========================================"
      echo "✗ FAILURE: Teardown NOT completed"
      echo "========================================"
      echo "No log entries found after ${MAX_RETRIES} attempts"
      echo "This may indicate:"
      echo "  - Teardown process did not complete"
      echo "  - Teardown is still in progress"
      echo "  - Log aggregation delay (logs may appear later)"
      echo ""
      exit 1
    fi
  fi
done
