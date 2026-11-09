#!/usr/bin/env bash
# Sends a phone notification through ntfy.sh (does nothing if NTFY_TOPIC is not set).
[ -n "${NTFY_TOPIC:-}" ] || exit 0
curl -fsS -H "Title: $1" -d "$2" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
exit 0
