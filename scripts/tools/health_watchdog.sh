#!/bin/bash
#
# Purpose: Station health watchdog, run hourly from cron. Checks that the
#          station is actually producing captures and alerts through the
#          enabled push channels (Telegram, Discord, Pushover, Slack, webhook)
#          when something is wrong - an unattended station otherwise fails
#          silently until someone notices weeks of missing passes.
#
# Checks performed:
#   - no successfully decoded capture within the configured number of hours
#   - every recent pass failed (decoder/SDR problems even though jobs run)
#   - disk usage of the image storage at or above the configured threshold
#   - no 'at' jobs scheduled at all (scheduler/TLE download broken)
#   - RTL-SDR receivers only: no RTL device visible on USB
#
# Each distinct alert is re-sent at most once per 24 hours (state kept in
# ~/.rn2_watchdog_state) so a persistent failure doesn't flood the channels.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

if [ "${ENABLE_HEALTH_WATCHDOG}" != "true" ]; then
  exit 0
fi

MAX_HOURS_WITHOUT_CAPTURE=${WATCHDOG_MAX_HOURS_WITHOUT_CAPTURE:-48}
DISK_USAGE_THRESHOLD=${WATCHDOG_DISK_USAGE_THRESHOLD:-90}
REALERT_SECONDS=$((24 * 3600))
STATE_FILE="$HOME/.rn2_watchdog_state"
NOW=$(date '+%s')

touch "$STATE_FILE"

# send an alert for a named check unless the same check alerted within the
# re-alert window; alerts always land in the log, and additionally in every
# enabled push channel that supports plain text messages
alert() {
  local check_name=$1
  local message=$2

  local last_alert
  last_alert=$(grep "^${check_name} " "$STATE_FILE" | awk '{print $2}')
  if [ -n "$last_alert" ] && [ $((NOW - last_alert)) -lt $REALERT_SECONDS ]; then
    log "Watchdog: ${check_name} still failing (suppressing re-alert): ${message}" "WARN"
    return 0
  fi
  grep -v "^${check_name} " "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  echo "${check_name} ${NOW}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"

  local full_message="Station alert"
  if [ -n "${GROUND_STATION_LOCATION}" ]; then
    full_message="${full_message} (${GROUND_STATION_LOCATION})"
  fi
  full_message="${full_message}: ${message}"
  log "Watchdog: ${full_message}" "ERROR"

  if [ "${ENABLE_TELEGRAM_PUSH}" == "true" ]; then
    curl --silent -X POST \
      -F chat_id="${TELEGRAM_CHAT_ID}" \
      -F text="${full_message}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >> $NOAA_LOG 2>&1
  fi

  if [ "${ENABLE_DISCORD_PUSH}" == "true" ] && [ -n "${DISCORD_NOAA_WEBHOOK}" ]; then
    curl --silent -H "Content-Type: application/json" \
      -d "{\"content\":\"${full_message}\"}" \
      "${DISCORD_NOAA_WEBHOOK}" >> $NOAA_LOG 2>&1
  fi

  if [ "${ENABLE_PUSHOVER_PUSH}" == "true" ]; then
    curl --silent \
      -F "token=${PUSHOVER_APITOKEN}" \
      -F "user=${PUSHOVER_USER}" \
      -F "priority=${PUSHOVER_PRIO}" \
      -F "message=${full_message}" \
      "https://api.pushover.net/1/messages.json" >> $NOAA_LOG 2>&1
  fi

  if [ "${ENABLE_SLACK_PUSH}" == "true" ]; then
    ${PUSH_PROC_DIR}/push_slack.sh "${full_message}" >> $NOAA_LOG 2>&1
  fi

  if [ "${ENABLE_WEBHOOK_PUSH}" == "true" ] && [ -n "${WEBHOOK_PUSH_URL}" ]; then
    auth_header=()
    if [ -n "${WEBHOOK_PUSH_AUTH_TOKEN}" ]; then
      auth_header=(-H "Authorization: Bearer ${WEBHOOK_PUSH_AUTH_TOKEN}")
    fi
    payload=$(jq -n --arg check "$check_name" --arg message "$full_message" \
      '{event: "station_alert", check: $check, message: $message}')
    curl --silent -X POST -H "Content-Type: application/json" \
      "${auth_header[@]}" --data "${payload}" "${WEBHOOK_PUSH_URL}" >> $NOAA_LOG 2>&1
  fi
}

# clear a check's alert state once it is healthy again so the next failure
# alerts immediately
clear_alert() {
  local check_name=$1
  grep -v "^${check_name} " "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# --- check: a capture succeeded recently ---
cutoff=$((NOW - MAX_HOURS_WITHOUT_CAPTURE * 3600))
recent_captures=$($SQLITE3 -cmd ".timeout 30000" "$DB_FILE" \
  "SELECT count(*) FROM decoded_passes WHERE pass_start > ${cutoff};")
if [ "${recent_captures:-0}" -eq 0 ]; then
  alert "no_recent_capture" "no successfully decoded capture in the last ${MAX_HOURS_WITHOUT_CAPTURE} hours - check ${NOAA_LOG}"
else
  clear_alert "no_recent_capture"
fi

# --- check: recent passes are not all failing ---
failed_recent=$($SQLITE3 -cmd ".timeout 30000" "$DB_FILE" \
  "SELECT count(*) FROM predict_passes WHERE pass_start > $((NOW - 86400)) AND pass_start < ${NOW} AND status = 'failed';")
attempted_recent=$($SQLITE3 -cmd ".timeout 30000" "$DB_FILE" \
  "SELECT count(*) FROM predict_passes WHERE pass_start > $((NOW - 86400)) AND pass_start < ${NOW} AND status IS NOT NULL;")
if [ "${attempted_recent:-0}" -ge 3 ] && [ "${failed_recent:-0}" -eq "${attempted_recent:-0}" ]; then
  alert "all_passes_failing" "all ${attempted_recent} passes in the last 24 hours failed - check the SDR and ${NOAA_LOG}"
else
  clear_alert "all_passes_failing"
fi

# --- check: disk usage of image storage ---
disk_usage=$(df --output=pcent "${IMAGE_OUTPUT}" 2>/dev/null | tail -1 | tr -d ' %')
if [ -n "$disk_usage" ] && [ "$disk_usage" -ge "$DISK_USAGE_THRESHOLD" ]; then
  alert "disk_usage" "image storage is ${disk_usage}% full (threshold ${DISK_USAGE_THRESHOLD}%) - prune captures or lower retention settings"
else
  clear_alert "disk_usage"
fi

# --- check: passes are scheduled at all ---
at_jobs=$(atq 2>/dev/null | wc -l)
if [ "${at_jobs:-0}" -eq 0 ]; then
  alert "no_scheduled_passes" "no 'at' jobs are scheduled - pass scheduling appears broken (TLE download or schedule.sh failure?)"
else
  clear_alert "no_scheduled_passes"
fi

# --- check: RTL-SDR visible on USB (other receiver types are not probed) ---
if [ "${RECEIVER_TYPE}" == "rtlsdr" ] && command -v lsusb >/dev/null 2>&1; then
  if ! lsusb | grep -qiE 'RTL2838|RTL2832|Realtek.*DVB|0bda:2838|0bda:2832'; then
    alert "sdr_missing" "no RTL-SDR device visible on USB - is the dongle unplugged or hung?"
  else
    clear_alert "sdr_missing"
  fi
fi

log "Watchdog run complete (captures last ${MAX_HOURS_WITHOUT_CAPTURE}h: ${recent_captures}, at jobs: ${at_jobs}, disk: ${disk_usage:-?}%)" "DEBUG"
