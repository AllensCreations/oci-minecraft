#!/usr/bin/env bash
# Finds the VM from the stack, opens the port, copies minecraft/ to it and runs server_setup.sh.
set -euo pipefail
[ -f minecraft/settings.env ] && . minecraft/settings.env
EDITION="${EDITION:-bedrock}"
UDP_PORT="${SERVER_PORT:-19132}"
TCP_PORT="${JAVA_PORT:-25565}"
case "$EDITION" in
  java) PORTS="tcp:$TCP_PORT" ;;
  java-geyser) PORTS="tcp:$TCP_PORT udp:$UDP_PORT" ;;
  *) PORTS="udp:$UDP_PORT" ;;
esac

oci resource-manager stack get-stack-tf-state --stack-id "$STACK_ID" --file state.json >/dev/null 2>&1 || echo '{}' > state.json
INSTANCE_ID=$(jq -r '[.resources[]? | select(.type=="oci_core_instance") | .instances[]?.attributes.id][0] // empty' state.json 2>/dev/null || true)
IP=$(jq -r '[.resources[]? | select(.type=="oci_core_instance") | .instances[]?.attributes.public_ip | select(. != null and . != "")][0] // empty' state.json 2>/dev/null || true)
if [ -z "$IP" ] && [ -n "$INSTANCE_ID" ]; then
  IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)
fi
if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  echo "No instance with a public IP found in the stack yet."
  [ "${REQUIRE_VM:-0}" = "1" ] && exit 1
  exit 0
fi
echo "Server IP: $IP"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "ip=$IP" >> "$GITHUB_OUTPUT"

if [ -n "$INSTANCE_ID" ]; then
  for p in $PORTS; do
    bash scripts/open_port.sh "$INSTANCE_ID" "${p#*:}" "${p%%:*}" || echo "WARNING: could not open ${p%%:*} ${p#*:} in the VCN; open it manually in the security list."
  done
fi

mkdir -p ~/.ssh
printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/id_deploy
chmod 600 ~/.ssh/id_deploy
SSHO="-i $HOME/.ssh/id_deploy -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"

USER_FOUND=""
for i in $(seq 1 30); do
  for u in ubuntu opc; do
    if ssh $SSHO "$u@$IP" true 2>/dev/null; then USER_FOUND="$u"; break 2; fi
  done
  echo "Waiting for SSH ($i/30)..."; sleep 10
done
[ -n "$USER_FOUND" ] || { echo "SSH not reachable (check SSH key / port 22)."; exit 1; }
echo "SSH user: $USER_FOUND"

if [ "${SKIP_IF_INSTALLED:-0}" = "1" ] && ssh $SSHO "$USER_FOUND@$IP" "systemctl is-active -q minecraft"; then
  echo "Server already running - skipping reinstall."; exit 0
fi
tar czf - minecraft scripts/server_setup.sh | ssh $SSHO "$USER_FOUND@$IP" 'rm -rf "$HOME/deploy" && mkdir -p "$HOME/deploy" && tar xzf - -C "$HOME/deploy"'
ssh $SSHO "$USER_FOUND@$IP" 'sudo bash "$HOME/deploy/scripts/server_setup.sh"'
echo "Server address: $IP   (Bedrock UDP $UDP_PORT / Java TCP $TCP_PORT, depending on edition: $EDITION)"
