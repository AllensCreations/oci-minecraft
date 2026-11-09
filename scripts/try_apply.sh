#!/usr/bin/env bash
# Runs an apply job on your OCI Resource Manager stack and waits for the result.
set -u
JOB=$(oci resource-manager job create-apply-job \
  --stack-id "$STACK_ID" \
  --execution-plan-strategy AUTO_APPROVED \
  --query 'data.id' --raw-output) || { echo "result=ERROR" >> "$GITHUB_OUTPUT"; exit 0; }
echo "Job: $JOB"
STATE=UNKNOWN
for i in $(seq 1 60); do
  STATE=$(oci resource-manager job get --job-id "$JOB" --query 'data."lifecycle-state"' --raw-output)
  echo "State: $STATE"
  case "$STATE" in SUCCEEDED|FAILED|CANCELED) break ;; esac
  sleep 20
done
echo "result=$STATE" >> "$GITHUB_OUTPUT"
exit 0
