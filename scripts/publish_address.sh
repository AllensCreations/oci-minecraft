#!/usr/bin/env bash
# Writes the VM's IP to web/config.json and pushes it, so the status page (Vercel) picks it up.
set -e
IP="${1:-}"; [ -n "$IP" ] || exit 0
mkdir -p web
printf '{"host":"%s"}\n' "$IP" > web/config.json
git config user.name "github-actions"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add web/config.json
git diff --cached --quiet && exit 0
git commit -m "Update server address"
git pull --rebase origin main || true
git push origin HEAD:main
