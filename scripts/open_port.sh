#!/usr/bin/env bash
# Opens a port in the VCN security list of the instance's subnet.
# usage: open_port.sh <instance-ocid> <port> <tcp|udp>
set -euo pipefail
INSTANCE_ID="$1"; PORT="$2"; PROTO="${3:-udp}"
if [ "$PROTO" = "tcp" ]; then NUM=6; KEY=tcp-options; CKEY=tcpOptions; else NUM=17; KEY=udp-options; CKEY=udpOptions; fi
SUBNET=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."subnet-id"' --raw-output)
SL=$(oci network subnet get --subnet-id "$SUBNET" --query 'data."security-list-ids"[0]' --raw-output)
oci network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' > rules_old.json
if jq -e --argjson p "$PORT" --arg n "$NUM" --arg k "$KEY" \
  'any(.[]; .protocol==$n and .[$k] != null and .[$k]."destination-port-range".min <= $p and .[$k]."destination-port-range".max >= $p)' rules_old.json >/dev/null; then
  echo "$PROTO $PORT already open in security list"; exit 0
fi
jq --argjson p "$PORT" --arg n "$NUM" --arg ck "$CKEY" '
  def camel: gsub("-(?<c>[a-z])"; (.c|ascii_upcase));
  def clean: walk(if type=="object" then with_entries(select(.value != null) | .key |= camel) else . end);
  (clean) + [{"protocol":$n,"source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,
    "description":"Minecraft",($ck):{"destinationPortRange":{"min":$p,"max":$p}}}]' \
  rules_old.json > rules_new.json
oci network security-list update --security-list-id "$SL" --ingress-security-rules file://rules_new.json --force >/dev/null
echo "Opened $PROTO $PORT in security list"
