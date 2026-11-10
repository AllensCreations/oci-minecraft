#!/usr/bin/env bash
set -u
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

BUSY=0
for s in ACCEPTED IN_PROGRESS; do
  N=$(oci resource-manager job list --stack-id "$STACK_ID" --lifecycle-state "$s" \
      --query 'length(data)' --raw-output 2>/dev/null || echo 0)
  BUSY=$((BUSY + ${N:-0}))
done
if [ "$BUSY" -gt 0 ]; then
  echo "A job is already running on this stack - skipping this round."
  echo "result=BUSY" >> "$GITHUB_OUTPUT"; exit 0
fi

JOB=$(oci resource-manager job create-apply-job \
  --stack-id "$STACK_ID" --execution-plan-strategy AUTO_APPROVED \
  --query 'data.id' --raw-output 2>/tmp/err) || {
    if grep -q TooManyRequests /tmp/err; then
      echo "Oracle rate limit (429) - will try again next round."
      echo "result=THROTTLED" >> "$GITHUB_OUTPUT"
    else
      cat /tmp/err; echo "result=ERROR" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  }
echo "Job: $JOB"

STATE=UNKNOWN
for i in $(seq 1 60); do
  STATE=$(oci resource-manager job get --job-id "$JOB" --query 'data."lifecycle-state"' --raw-output)
  echo "State: $STATE"
  case "$STATE" in SUCCEEDED|FAILED|CANCELED) break ;; esac
  sleep 20
done
if [ "$STATE" != "SUCCEEDED" ]; then
  echo "--- why it failed ---"
  oci resource-manager job get-job-logs --job-id "$JOB" --all --query 'data[].message' 2>/dev/null | grep -iE 'error|capacity|limit|quota' | head -n 8
fi
echo "result=$STATE" >> "$GITHUB_OUTPUT"
exit 0
