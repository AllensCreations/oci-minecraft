#!/usr/bin/env bash
set -u
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
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
if [ "$STATE" != "SUCCEEDED" ]; then
  echo "--- why it failed ---"
  oci resource-manager job get-job-logs --job-id "$JOB" --all --query 'data[-6:].message' 2>/dev/null | tail -n 12
fi
echo "result=$STATE" >> "$GITHUB_OUTPUT"
exit 0
