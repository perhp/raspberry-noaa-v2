#!/bin/bash
#
# Purpose: POST a JSON payload describing a completed capture to a
#          user-configured webhook URL. This makes integrations with
#          Home Assistant, n8n, Node-RED, or any custom endpoint possible
#          without a dedicated push processor per service.
#
# Input parameters:
#   1. Pass id (decoded_passes.id)
#   2. Daylight pass flag (1 = day, 0 = night)
#   3+. List of image paths produced by the capture (can be 0-many)
#
# The remaining pass metadata (SAT_NAME, EPOCH_START, CAPTURE_TIME,
# SAT_MAX_ELEVATION, PASS_DIRECTION, PASS_SIDE, SUN_ELEV, GAIN) is read from
# the environment exported by the receive_* scripts.
#
# Example:
#   ./scripts/push_processors/push_webhook.sh 123 1 "/srv/images/NOAA-18-20210212-091356-MCIR.jpg"

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

# input params
PASS_ID=$1
DAYLIGHT=$2
shift 2

if [ -z "${WEBHOOK_PUSH_URL}" ]; then
  log "No webhook URL configured - check webhook_push_url in settings.yml" "ERROR"
  exit 1
fi

# numeric fields default to 0 so an unset variable cannot produce invalid JSON
payload=$(jq -n \
  --arg sat_name "${SAT_NAME}" \
  --arg direction "${PASS_DIRECTION}" \
  --arg side "${PASS_SIDE}" \
  --arg ground_station "${GROUND_STATION_LOCATION}" \
  --argjson pass_id "${PASS_ID:-0}" \
  --argjson pass_start "${EPOCH_START:-0}" \
  --argjson duration "${CAPTURE_TIME:-0}" \
  --argjson max_elevation "${SAT_MAX_ELEVATION:-0}" \
  --argjson sun_elevation "${SUN_ELEV:-0}" \
  --argjson gain "${GAIN:-0}" \
  --argjson daylight "$([ "${DAYLIGHT}" == "1" ] && echo true || echo false)" \
  --args \
  '{
    event: "capture_complete",
    satellite: $sat_name,
    pass_id: $pass_id,
    pass_start: $pass_start,
    pass_end: ($pass_start + $duration),
    duration_seconds: $duration,
    max_elevation: $max_elevation,
    pass_direction: $direction,
    pass_side: $side,
    sun_elevation: $sun_elevation,
    gain: $gain,
    daylight_pass: $daylight,
    ground_station: $ground_station,
    images: $ARGS.positional
  }' "$@")

if [ -z "$payload" ]; then
  log "Failed to construct webhook JSON payload - not sending" "ERROR"
  exit 1
fi

auth_header=()
if [ -n "${WEBHOOK_PUSH_AUTH_TOKEN}" ]; then
  auth_header=(-H "Authorization: Bearer ${WEBHOOK_PUSH_AUTH_TOKEN}")
fi

log "Sending capture event for pass ${PASS_ID} to webhook" "INFO"
push_log=$(curl --silent --show-error -X POST \
           -H "Content-Type: application/json" \
           "${auth_header[@]}" \
           --data "${payload}" \
           "${WEBHOOK_PUSH_URL}" 2>&1)
log "${push_log}" "INFO"
