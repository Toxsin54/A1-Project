#!/usr/bin/env bash
# Vapi'nin n8n webhook'una gönderdiği tool-calls isteğini taklit eder.
#
#   WEBHOOK_URL=http://localhost:5678/webhook/vapi/reservations \
#   VAPI_WEBHOOK_SECRET=gizli ./test/simulate_vapi.sh check_availability \
#     '{"room_type":"deluxe","check_in":"2026-10-05","check_out":"2026-10-08","guests":2}'
#
# Arayan numara 3. parametre ile verilebilir (varsayılan +905321112233).
set -euo pipefail

TOOL="${1:?kullanım: $0 <tool_name> '<json args>' [arayan_numara]}"
ARGS="${2:-}"
[ -n "$ARGS" ] || ARGS='{}'
CALLER="${3:-+905321112233}"
URL="${WEBHOOK_URL:-http://localhost:5678/webhook/vapi/reservations}"

curl -sS -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H "X-Vapi-Secret: ${VAPI_WEBHOOK_SECRET:-}" \
  -d @- <<JSON
{
  "message": {
    "type": "tool-calls",
    "call": { "id": "test-call-$(date +%s)", "customer": { "number": "$CALLER" } },
    "toolCallList": [
      { "id": "call_$(date +%s%N)", "type": "function",
        "function": { "name": "$TOOL", "arguments": $ARGS } }
    ]
  }
}
JSON
echo
