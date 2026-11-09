#!/data/data/com.termux/files/usr/bin/bash
# Creates a PUBLIC GitHub repo from this folder, sets the secrets, and starts the workflow.
set -e
cd "$(dirname "$0")/.."

echo "== Installing tools =="
pkg update -y
pkg install -y git gh

echo "== GitHub login =="
if ! gh auth status >/dev/null 2>&1; then
  gh auth login
fi
OWNER=$(gh api user --jq .login)
git config --global user.name "$OWNER"
git config --global user.email "${OWNER}@users.noreply.github.com"

read -p "Repo name [oci-minecraft]: " REPO
REPO=${REPO:-oci-minecraft}

echo "== Creating public repo $OWNER/$REPO =="
[ -d .git ] || git init -b main
git add -A
git commit -m "Initial commit" || true
gh repo create "$OWNER/$REPO" --public --source=. --remote=origin --push

echo "== Setting secrets (stored encrypted on GitHub, not in the repo) =="
read -p "OCI_USER (user OCID): " V;        gh secret set OCI_USER --repo "$OWNER/$REPO" --body "$V"
read -p "OCI_TENANCY (tenancy OCID): " V;  gh secret set OCI_TENANCY --repo "$OWNER/$REPO" --body "$V"
read -p "OCI_FINGERPRINT: " V;             gh secret set OCI_FINGERPRINT --repo "$OWNER/$REPO" --body "$V"
read -p "OCI_REGION (e.g. ap-mumbai-1): " V; gh secret set OCI_REGION --repo "$OWNER/$REPO" --body "$V"
read -p "OCI_STACK_ID (stack OCID): " V;   gh secret set OCI_STACK_ID --repo "$OWNER/$REPO" --body "$V"
read -p "Path to private key .pem (e.g. ~/storage/downloads/key.pem): " KP
KP="${KP/#\~/$HOME}"
gh secret set OCI_KEY --repo "$OWNER/$REPO" < "$KP"

read -p "Start the workflow now? [Y/n]: " GO
if [ "${GO:-Y}" != "n" ]; then
  gh workflow run retry.yml --repo "$OWNER/$REPO" || echo "Start it manually from the Actions tab."
fi
echo "Done: https://github.com/$OWNER/$REPO/actions"
