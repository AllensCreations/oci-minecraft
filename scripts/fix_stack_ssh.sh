#!/usr/bin/env bash
# Runs on GitHub. Puts the public half of the SSH_PRIVATE_KEY secret into the Oracle stack.
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
say(){ echo "FIXSSH $*"; }

printf '%s\n' "$SSH_PRIVATE_KEY" > k.pem; chmod 600 k.pem
PUB=$(ssh-keygen -y -f k.pem 2>/dev/null | awk '{print $1" "$2" oci-minecraft"}')
rm -f k.pem
[ -n "$PUB" ] && [ "$PUB" != " oci-minecraft" ] || { say "[FAIL] SSH_PRIVATE_KEY is not a valid private key"; exit 0; }
BODY=$(echo "$PUB" | awk '{print $2}')

oci resource-manager stack get --stack-id "$STACK_ID" > stack.json 2>err.txt || { say "[FAIL] cannot read the stack: $(head -c 200 err.txt | tr '\n' ' ')"; exit 0; }
oci resource-manager stack get-stack-tf-config --stack-id "$STACK_ID" --file cfg.zip >/dev/null 2>&1 || { say "[FAIL] cannot download the stack configuration"; exit 0; }
rm -rf cfg && mkdir cfg && unzip -oq cfg.zip -d cfg

CHANGED=0
# Case A: the key is a stack variable
CH=$(jq '[.data.variables // {} | to_entries[] | select((.key|test("ssh";"i")) and ((.value|tostring)|test("ssh-")))] | length' stack.json 2>/dev/null || echo 0)
if [ "${CH:-0}" -gt 0 ]; then
  jq --arg pub "$PUB" '.data.variables // {} | with_entries(if ((.key|test("ssh";"i")) and ((.value|tostring)|test("ssh-"))) then .value=$pub else . end)' stack.json > vars.json
  if oci resource-manager stack update --stack-id "$STACK_ID" --variables file://vars.json --force >/dev/null 2>err.txt; then
    say "[ok]   Updated $CH SSH variable(s) in the stack"; CHANGED=1
  else say "[FAIL] variable update failed: $(head -c 200 err.txt | tr '\n' ' ')"; fi
fi
# Case B: the key is written inside the Terraform files
if grep -rqE '"ssh-(rsa|ed25519|ecdsa-sha2-[a-z0-9]+) ' cfg 2>/dev/null; then
  find cfg -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.json' \) -exec sed -i -E "s#\"ssh-(rsa|ed25519|ecdsa-sha2-[a-z0-9]+) [^\"]*\"#\"$PUB\"#g" {} +
  rm -f new.zip; (cd cfg && zip -qr ../new.zip .)
  if oci resource-manager stack update --stack-id "$STACK_ID" --config-source new.zip --force >/dev/null 2>err.txt; then
    say "[ok]   Replaced the SSH key inside the stack's Terraform files"; CHANGED=1
  else say "[FAIL] configuration update failed: $(head -c 200 err.txt | tr '\n' ' ')"; fi
fi

if [ "$CHANGED" = "0" ]; then
  say "[FAIL] No SSH key found in the stack variables or Terraform files."
  say "       Variables with 'ssh' in the name: $(jq -r '[.data.variables // {} | keys[] | select(test("ssh";"i"))] | join(", ")' stack.json 2>/dev/null)"
  say "       Add the public key to the stack by hand (see the chat instructions)."
  exit 0
fi

# verify
oci resource-manager stack get --stack-id "$STACK_ID" > stack2.json 2>/dev/null
oci resource-manager stack get-stack-tf-config --stack-id "$STACK_ID" --file cfg2.zip >/dev/null 2>&1
rm -rf cfg2 && mkdir cfg2 && unzip -oq cfg2.zip -d cfg2 2>/dev/null
if grep -qF "$BODY" stack2.json 2>/dev/null || grep -rqF "$BODY" cfg2 2>/dev/null; then
  say "[ok]   Verified: the stack now contains your new public key"
else
  say "[warn] Updated, but could not re-verify. Run the preflight check."
fi
exit 0
