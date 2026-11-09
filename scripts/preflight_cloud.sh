#!/usr/bin/env bash
# Runs on GitHub: checks the stack and download links. Prints only yes/no results (no OCIDs or keys).
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
ok(){ echo "PREFLIGHT [ok]   $*"; }
bad(){ echo "PREFLIGHT [FAIL] $*"; }
warn(){ echo "PREFLIGHT [warn] $*"; }

echo "PREFLIGHT --- Oracle login and stack ---"
if oci resource-manager stack get --stack-id "$STACK_ID" > stack.json 2>stack.err; then
  ok "Logged in to Oracle and the stack can be read"
else
  bad "Cannot read the stack (wrong OCID, key or region): $(head -c 200 stack.err | tr '\n' ' ')"; exit 0
fi
[ "$(jq -r '.data."lifecycle-state"' stack.json)" = "ACTIVE" ] && ok "Stack state is ACTIVE" || warn "Stack state is not ACTIVE"
case "$STACK_ID" in *".${OCI_REGION}."*) ok "Stack is in region $OCI_REGION" ;; *) bad "Stack region does not match OCI_REGION ($OCI_REGION)" ;; esac

# collect the stack's variables and Terraform files as text
TXT=$(jq -r '.data.variables // {} | to_entries[] | "\(.key)=\(.value)"' stack.json 2>/dev/null)
if oci resource-manager stack get-stack-tf-config --stack-id "$STACK_ID" --file cfg.zip >/dev/null 2>&1; then
  mkdir -p cfg && unzip -oq cfg.zip -d cfg 2>/dev/null || true
  TXT="$TXT
$(cat $(find cfg -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.yaml' \) 2>/dev/null) 2>/dev/null)"
fi

echo "$TXT" | grep -q "A1.Flex" && ok "Shape VM.Standard.A1.Flex found (Ampere, Always Free)" || warn "Could not find VM.Standard.A1.Flex in the stack"
echo "$TXT" | grep -qiE 'assign_public_ip|assignPublicIp' && ok "Public IP setting present in the stack" || warn "No public-IP setting found - the VM needs a public IP"

if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$SSH_PRIVATE_KEY" > k.pem; chmod 600 k.pem
  PUB=$(ssh-keygen -y -f k.pem 2>/dev/null | awk '{print $2}')
  if [ -z "$PUB" ]; then bad "SSH_PRIVATE_KEY secret is not a valid private key"
  elif echo "$TXT" | grep -qF "$PUB"; then ok "SSH key matches the public key in the stack"
  else bad "SSH key does NOT match any public key in the stack - paste the installer's public key into the stack and save"; fi
  rm -f k.pem
else
  bad "SSH_PRIVATE_KEY secret is missing"
fi

IMG=$(echo "$TXT" | grep -oE 'ocid1\.image\.[A-Za-z0-9._-]+' | head -1)
if [ -n "$IMG" ]; then
  NAME=$(oci compute image get --image-id "$IMG" --query 'data."display-name"' --raw-output 2>/dev/null)
  if echo "$NAME" | grep -qi ubuntu && echo "$NAME" | grep -qiE 'aarch64|arm'; then ok "Image looks like Ubuntu ARM: $NAME"
  elif [ -n "$NAME" ]; then warn "Image is '$NAME' - the install expects Ubuntu on ARM (aarch64)"
  else warn "Could not look up the image"; fi
else
  warn "No image OCID found in the stack text (it may be chosen by a variable at apply time)"
fi

echo "PREFLIGHT --- Downloads (java-geyser) ---"
V=$(curl -fsSL https://fill.papermc.io/v3/projects/paper | jq -r '[.versions | to_entries[] | .value[]] | .[0] // empty' 2>/dev/null)
[ -z "$V" ] && V=$(curl -fsSL https://api.papermc.io/v2/projects/paper | jq -r '.versions[-1] // empty' 2>/dev/null)
if [ -n "$V" ]; then
  U=$(curl -fsSL "https://fill.papermc.io/v3/projects/paper/versions/$V/builds/latest" | jq -r '.downloads["server:default"].url // empty' 2>/dev/null)
  if [ -z "$U" ]; then B=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/$V/builds" | jq -r '.builds[-1].build // empty' 2>/dev/null); [ -n "$B" ] && U="https://api.papermc.io/v2/projects/paper/versions/$V/builds/$B/downloads/paper-$V-$B.jar"; fi
  if [ -n "$U" ] && curl -fsSIL "$U" >/dev/null 2>&1; then ok "Paper $V download works"; else bad "Paper $V: no working download link found"; fi
else
  bad "Could not read Paper's version list"
fi
for p in geyser floodgate; do
  curl -fsSIL "https://download.geysermc.org/v2/projects/$p/versions/latest/builds/latest/downloads/spigot" >/dev/null 2>&1 \
    && ok "$p download works" || bad "$p download link failed"
done
exit 0
