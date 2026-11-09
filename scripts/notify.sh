#!/usr/bin/env bash
[ -n "${NTFY_TOPIC:-}" ] || exit 0
ARGS=(-H "Title: $1")
BODY="$2"
if [ -n "${STATUS_URL:-}" ]; then
  ARGS+=(-H "Click: $STATUS_URL" -H "Actions: view, Open status page, $STATUS_URL")
  BODY="$2"$'\n'"Status page: $STATUS_URL"
fi
curl -fsS "${ARGS[@]}" -d "$BODY" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
exit 0
