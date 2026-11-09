#!/usr/bin/env bash
# Run in Termux from your repo folder:  bash scripts/preflight.sh
# Checks your local setup, then runs the cloud checks on GitHub and prints the results.
cd "$(dirname "$0")/.."
ok(){ echo "  [ok]   $*"; }; bad(){ echo "  [FAIL] $*"; }; warn(){ echo "  [warn] $*"; }
command -v gh >/dev/null || { echo "Install gh first: pkg install gh"; exit 1; }
R=$(gh repo view --json nameWithOwner -q .nameWithOwner) || { echo "Run this inside your repo folder"; exit 1; }
echo "Checking $R"

echo "--- This device ---"
{ : < /dev/tty; } 2>/dev/null && ok "Terminal input (/dev/tty) works for the installer" || warn "No /dev/tty: run the installer with  curl -fsSL <url> -o install.sh && bash install.sh"
gh auth status >/dev/null 2>&1 && ok "Logged in to GitHub" || bad "Not logged in: run gh auth login"

echo "--- GitHub secrets and settings ---"
SECRETS=$(gh secret list --repo "$R" 2>/dev/null | awk '{print $1}')
for s in OCI_USER OCI_TENANCY OCI_FINGERPRINT OCI_REGION OCI_KEY OCI_STACK_ID SSH_PRIVATE_KEY; do
  echo "$SECRETS" | grep -qx "$s" && ok "secret $s is set" || bad "secret $s is MISSING"
done
echo "$SECRETS" | grep -qx NTFY_TOPIC && ok "secret NTFY_TOPIC is set (notifications on)" || warn "NTFY_TOPIC not set (no phone notifications)"
gh variable list --repo "$R" 2>/dev/null | awk '{print $1}' | grep -qx STATUS_URL && ok "variable STATUS_URL is set" || warn "STATUS_URL not set (notification has no Vercel link)"
gh workflow list --repo "$R" 2>/dev/null | grep -q "Retry OCI stack apply" && ok "Retry workflow is enabled" || warn "Retry workflow is disabled or missing: gh workflow enable retry.yml"

echo "--- Edition settings ---"
if [ -f minecraft/settings.env ]; then
  . minecraft/settings.env
  echo "  edition: ${EDITION:-bedrock}"
  case "${EDITION:-bedrock}" in
    java|java-geyser) [ "${EULA:-false}" = "true" ] && ok "EULA accepted" || bad "EULA is not true in minecraft/settings.env" ;;
    *) warn "Bedrock edition runs emulated on ARM and may fail; java-geyser is safer" ;;
  esac
else bad "minecraft/settings.env is missing"; fi

echo "--- Cloud checks (running on GitHub, about a minute) ---"
git add -A >/dev/null 2>&1; git diff --cached --quiet || { echo "  (you have uncommitted changes; commit and push first)"; }
gh workflow run preflight.yml --repo "$R" >/dev/null 2>&1 || { bad "Could not start preflight.yml (push the update first)"; exit 1; }
sleep 8
RUN=$(gh run list --workflow=preflight.yml --repo "$R" -L 1 --json databaseId -q '.[0].databaseId')
for i in $(seq 1 40); do
  ST=$(gh run view "$RUN" --repo "$R" --json status -q .status)
  [ "$ST" = "completed" ] && break
  sleep 6
done
gh run view "$RUN" --repo "$R" --log 2>/dev/null | grep "PREFLIGHT" | sed -E 's/^.*PREFLIGHT //'
echo
echo "Fix any [FAIL] lines first. [warn] lines are worth a look but not blocking."
