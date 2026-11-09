#!/usr/bin/env bash
# One-time interactive setup. After it finishes, everything runs automatically on GitHub.
#   bash <(curl -fsSL https://raw.githubusercontent.com/AllensCreations/oci-minecraft/main/install.sh)
set -e
UPSTREAM="${UPSTREAM:-AllensCreations/oci-minecraft}"

say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ask(){ local a; if [ -n "${3:-}" ]; then read -r -p "$1 [$3]: " a < /dev/tty; a="${a:-$3}"; else read -r -p "$1: " a < /dev/tty; fi; printf -v "$2" '%s' "$a"; }
ask_req(){ local v=""; while [ -z "$v" ]; do ask "$1" v "${3:-}"; done; printf -v "$2" '%s' "$v"; }
ocid_ok(){ case "$1" in "$2"*) [ ${#1} -ge 60 ];; *) return 1;; esac; }
ask_ocid(){ local v="${!2:-}"; while ! ocid_ok "$v" "$3"; do [ -n "$v" ] && echo "  Not valid: must start with $3 and be the full OCID."; ask "$1" v; done; printf -v "$2" '%s' "$v"; }
ask_file(){ local v=""; while true; do ask "$1" v; v="${v%\"}"; v="${v#\"}"; v="${v/#\~/$HOME}"
  if [ -f "$v" ] && { [ -z "${3:-}" ] || grep -q "$3" "$v"; }; then break; fi
  echo "  File not found, or it is the wrong kind of key. Try again."; done; printf -v "$2" '%s' "$v"; }
choice(){ local v=""; while true; do ask "$1 ($3)" v "$4"; for o in $(echo "$3" | tr '/' ' '); do [ "$v" = "$o" ] && break 2; done; echo "  Pick one of: $3"; done; printf -v "$2" '%s' "$v"; }
need(){ command -v "$1" >/dev/null 2>&1; }

say "Checking tools"
if ! need git || ! need gh; then
  if need pkg; then pkg install -y git gh
  elif need apt-get; then sudo apt-get update && sudo apt-get install -y git gh
  elif need brew; then brew install git gh
  else echo "Please install git and the GitHub CLI (gh), then run again."; exit 1; fi
fi

say "GitHub login"
gh auth status >/dev/null 2>&1 || gh auth login < /dev/tty
OWNER=$(gh api user --jq .login)
echo "Logged in as $OWNER"

say "Your new repo"
ask_req "Repo name" REPO "oci-minecraft"
S="$OWNER/$REPO"
EXISTS=0
if gh repo view "$S" >/dev/null 2>&1; then
  EXISTS=1
  echo "Repo $S already exists: it will be updated (files replaced, secrets overwritten)."
else
  choice "Visibility" VIS "public/private" "public"
fi

say "Oracle Cloud values"
echo "Paste your whole OCI config block (the [DEFAULT] text with user=, fingerprint=,"
echo "tenancy=, region=). It continues by itself once all four are found."
echo "Or just press Enter on an empty line to type each value."
CFGTXT=""
getv(){ printf '%s\n' "$CFGTXT" | grep -E "^[[:space:]]*$1[[:space:]]*=" | head -1 | sed -E "s/^[^=]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//" | tr -d '\r'; }
while IFS= read -r line < /dev/tty; do
  [ -z "$line" ] && break
  CFGTXT="$CFGTXT"$'\n'"$line"
  [ -n "$(getv user)" ] && [ -n "$(getv fingerprint)" ] && [ -n "$(getv tenancy)" ] && [ -n "$(getv region)" ] && break
done
# discard any leftover pasted lines (e.g. the key_file= line) so they are not read as answers
while IFS= read -r -t 0.5 _ < /dev/tty; do :; done
OCI_USER=$(getv user); OCI_FINGERPRINT=$(getv fingerprint); OCI_TENANCY=$(getv tenancy); OCI_REGION=$(getv region)
[ -n "$OCI_USER$OCI_TENANCY" ] && echo "Read from pasted config: region=${OCI_REGION:-?}, fingerprint=${OCI_FINGERPRINT:-?}"
ask_ocid "User OCID (ocid1.user...)" OCI_USER "ocid1.user."
ask_ocid "Tenancy OCID (ocid1.tenancy...)" OCI_TENANCY "ocid1.tenancy."
[ -n "$OCI_FINGERPRINT" ] || ask_req "API key fingerprint (xx:xx:xx...)" OCI_FINGERPRINT
[ -n "$OCI_REGION" ] || ask_req "Region (e.g. ap-singapore-1)" OCI_REGION
ask_ocid "Resource Manager stack OCID (ocid1.ormstack...)" OCI_STACK_ID "ocid1.ormstack."
# --- OCI API private key: auto-detect newest private .pem in Downloads ---
FOUND=""
for d in "$HOME/storage/downloads" "$HOME/Downloads"; do
  [ -d "$d" ] || continue
  while IFS= read -r x; do
    case "$x" in *_public*) continue ;; esac
    if grep -q "PRIVATE KEY" "$x" 2>/dev/null; then FOUND="$x"; break; fi
  done < <(ls -t "$d"/*.pem 2>/dev/null)
  [ -n "$FOUND" ] && break
done
OCI_KEYFILE=""
if [ -n "$FOUND" ]; then
  echo "Found OCI private key: $FOUND"
  choice "Use it" USE_IT "yes/no" "yes"
  [ "$USE_IT" = "yes" ] && OCI_KEYFILE="$FOUND"
fi
[ -n "$OCI_KEYFILE" ] || ask_file "Path to your OCI API PRIVATE key (.pem, NOT the _public one)" OCI_KEYFILE "PRIVATE KEY"

# --- SSH key: generate a new one (needed only once the VM exists) ---
say "SSH key (used by GitHub to log in to the VM after it is created)"
choice "Create a new SSH key automatically" NEWSSH "yes/no" "yes"
SSH_PUB=""
if [ "$NEWSSH" = "yes" ]; then
  need ssh-keygen || { need pkg && pkg install -y openssh; } || { need apt-get && sudo apt-get install -y openssh-client; }
  mkdir -p "$HOME/.ssh"
  SSH_KEYFILE="$HOME/.ssh/${REPO}_ed25519"
  [ -f "$SSH_KEYFILE" ] || ssh-keygen -t ed25519 -N "" -C "$REPO" -f "$SSH_KEYFILE" -q
  SSH_PUB=$(cat "$SSH_KEYFILE.pub")
  echo
  echo "Add this PUBLIC key to your stack (Resource Manager > your stack > Edit > the SSH public key field),"
  echo "then save. The VM gets created with it:"
  echo
  echo "$SSH_PUB"
  echo
  echo "(Private key saved at $SSH_KEYFILE - keep it if you want to SSH into the server yourself.)"
  read -r -p "Press Enter once your stack uses this public key (or to continue anyway)... " _ < /dev/tty
else
  ask_file "Path to your existing SSH PRIVATE key (matches the public key in your stack)" SSH_KEYFILE "PRIVATE KEY"
fi

say "Server edition"
echo "  bedrock      = Bedrock server (x86 only: emulated on free ARM, slower)"
echo "  java-geyser  = Java server, Java AND Bedrock players can join (fast on ARM, recommended)"
echo "  java         = Java server only"
choice "Edition" EDITION "bedrock/java-geyser/java" "bedrock"
EULA=false
if [ "$EDITION" != "bedrock" ]; then
  choice "Do you accept the Minecraft EULA (https://aka.ms/MinecraftEULA)" EULA_A "yes/no" "yes"
  [ "$EULA_A" = "yes" ] && EULA=true || { echo "Java editions need the EULA accepted."; exit 1; }
fi

say "Server settings"
ask_req "Server name" S_NAME "My Minecraft Server"
choice "Game mode" S_MODE "survival/creative/adventure" "survival"
choice "Difficulty" S_DIFF "peaceful/easy/normal/hard" "easy"
ask_req "Max players" S_MAX "10"
if [ "$EDITION" = "bedrock" ]; then ask_req "World (level) name" S_LEVEL "Bedrock level"; else ask_req "World folder name (no spaces)" S_LEVEL "world"; S_LEVEL="${S_LEVEL// /_}"; fi
ask "World seed (blank = random)" S_SEED ""
ask_req "View distance (lower = faster)" S_VIEW "10"
S_CHEATS=false; S_ALLOW=""
if [ "$EDITION" = "bedrock" ]; then
  choice "Allow cheats" S_CHEATS "true/false" "false"
  ask "Allowed players' gamertags, comma separated (blank = anyone)" S_ALLOW ""
fi
choice "Keepalive so Oracle doesn't reclaim the idle VM" S_KEEP "yes/no" "yes"
ask "Server version (blank = latest)" S_VER ""
ask "Path to a world file (.zip / .mcworld) to import (blank = none)" P_WORLD ""
P_RES=""; P_BEH=""; P_PLUG=""
if [ "$EDITION" = "bedrock" ]; then
  ask "Path to resource pack file or folder (blank = none)" P_RES ""
  ask "Path to behavior pack file or folder (blank = none)" P_BEH ""
else
  ask "Path to plugin .jar file or folder (blank = none)" P_PLUG ""
fi

say "Creating $REPO"
DIR="$HOME/$REPO"
if [ -e "$DIR" ]; then mv "$DIR" "$DIR.bak-$(date +%s)"; echo "Moved the old local folder to $DIR.bak-*"; fi
git clone --depth 1 "https://github.com/$UPSTREAM.git" "$DIR"
cd "$DIR"
rm -rf .git

setp(){ grep -v "^$2=" "$1" > .tmp && printf '%s=%s\n' "$2" "$3" >> .tmp && mv .tmp "$1"; }
sete(){ sed -i "s|^$1=.*|$1=$2|" minecraft/settings.env; }
sete EDITION "$EDITION"; sete EULA "$EULA"; sete KEEPALIVE "$S_KEEP"
if [ "$EDITION" = "bedrock" ]; then
  sete BEDROCK_VERSION "$S_VER"
  F=minecraft/server.properties
  setp $F server-name "$S_NAME"; setp $F gamemode "$S_MODE"; setp $F difficulty "$S_DIFF"
  setp $F max-players "$S_MAX"; setp $F level-name "$S_LEVEL"; setp $F level-seed "$S_SEED"
  setp $F allow-cheats "$S_CHEATS"; setp $F view-distance "$S_VIEW"
  if [ -n "$S_ALLOW" ]; then
    setp $F allow-list true
    J="["; first=1
    IFS=',' read -ra NAMES <<< "$S_ALLOW"
    for n in "${NAMES[@]}"; do n="$(echo "$n" | sed 's/^ *//;s/ *$//')"; [ -n "$n" ] || continue
      [ $first = 1 ] || J="$J,"; first=0; J="$J{\"ignoresPlayerLimit\":false,\"name\":\"$n\"}"; done
    echo "$J]" > minecraft/allowlist.json
  fi
else
  sete PAPER_VERSION "$S_VER"
  F=minecraft/java.server.properties
  setp $F motd "$S_NAME"; setp $F gamemode "$S_MODE"; setp $F difficulty "$S_DIFF"
  setp $F max-players "$S_MAX"; setp $F level-name "$S_LEVEL"; setp $F level-seed "$S_SEED"
  setp $F view-distance "$S_VIEW"
fi

esc(){ printf '%s' "$1" | sed 's/[\\"]/\\&/g' | sed 's/[\\|&]/\\&/g'; }
sed -i "s|^  name: \".*\",|  name: \"$(esc "$S_NAME")\",|; s|edition: \"[a-z-]*\",|edition: \"$EDITION\",|; s|repo: \"[^\"]*\"|repo: \"$S\"|" web/index.html

copyin(){ local p="${1/#\~/$HOME}" dst="$2"; [ -n "$1" ] || return 0; mkdir -p "$dst"
  if [ -d "$p" ]; then cp -r "$p"/. "$dst/"; elif [ -f "$p" ]; then cp "$p" "$dst/"; else echo "  (not found: $p - skipped)"; fi; }
if [ -n "$P_WORLD" ]; then
  W="${P_WORLD/#\~/$HOME}"
  if [ -f "$W" ]; then
    [ "$(wc -c < "$W")" -gt 100000000 ] && echo "  WARNING: world is over 100 MB; GitHub will reject it. Upload it to the VM later instead."
    cp "$W" minecraft/world.zip
  else echo "  (world file not found - skipped)"; fi
fi
copyin "$P_RES" minecraft/resource_packs
copyin "$P_BEH" minecraft/behavior_packs
copyin "$P_PLUG" minecraft/plugins
[ -n "$P_RES" ] && setp minecraft/server.properties texturepack-required true

git init -q -b main
git config user.name "$OWNER"; git config user.email "${OWNER}@users.noreply.github.com"
git add -A; git commit -q -m "Initial setup"
if [ $EXISTS = 1 ]; then
  git remote add origin "https://github.com/$S.git"
else
  gh repo create "$S" "--$VIS" --source=. --remote=origin
fi

say "Saving secrets (encrypted on GitHub, never in the repo)"
gh secret set OCI_USER --repo "$S" --body "$OCI_USER"
gh secret set OCI_TENANCY --repo "$S" --body "$OCI_TENANCY"
gh secret set OCI_FINGERPRINT --repo "$S" --body "$OCI_FINGERPRINT"
gh secret set OCI_REGION --repo "$S" --body "$OCI_REGION"
gh secret set OCI_STACK_ID --repo "$S" --body "$OCI_STACK_ID"
gh secret set OCI_KEY --repo "$S" < "$OCI_KEYFILE"
gh secret set SSH_PRIVATE_KEY --repo "$S" < "$SSH_KEYFILE"

say "Publishing and starting"
gh auth setup-git >/dev/null 2>&1 || true
if [ $EXISTS = 1 ]; then git push -u --force origin main; else git push -u origin main; fi
gh workflow enable retry.yml --repo "$S" >/dev/null 2>&1 || true
gh workflow run retry.yml --repo "$S" || echo "Start it from the Actions tab."

cat <<MSG

All set. No more questions - GitHub does the rest:
  1. Retries your Oracle stack every ~10 minutes until capacity is free
  2. Installs and starts your $EDITION server
  3. Disables the retry job

Watch progress: https://github.com/$S/actions
Status page: import $S into Vercel with Root Directory "web" (see README).
Change settings later: edit files in minecraft/ and push (auto-applies).
You can delete the key files you downloaded now.
MSG
