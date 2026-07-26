#!/bin/bash
#
# Purpose: Send images and a message to a Telegram chat via the Bot API.
#
# Input parameters:
#   1. Message (used as the caption of the first image)
#   2+. List of image paths to send (can be 1-many)
#
# Example:
#   ./scripts/push_processors/push_telegram.sh "test annotation" "/srv/images/NOAA-18-20210212-091356-MCIR.jpg" \
#                                                                "/srv/images/NOAA-18-20210212-091356-HVC.jpg"

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

# input params
MESSAGE=$1
shift
IMAGES=$@

# check that telegram is configured
if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
  log "Telegram bot token or chat id not configured - check telegram_bot_token/telegram_chat_id in settings.yml" "ERROR"
  exit 1
fi

API_BASE="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# caption only the first image so an album of enhancements doesn't repeat
# the same text on every photo
caption="$MESSAGE"
for imagefile in $IMAGES; do
  if [ ! -f "${imagefile}" ]; then
    log "Could not find image ${imagefile} to post to Telegram - ignoring" "WARN"
    continue
  fi

  log "Sending ${imagefile} to Telegram chat ${TELEGRAM_CHAT_ID}" "INFO"
  push_log=$(curl --silent --show-error -X POST \
             -F chat_id="${TELEGRAM_CHAT_ID}" \
             -F photo=@"${imagefile}" \
             -F caption="${caption}" \
             "${API_BASE}/sendPhoto" 2>&1)
  log "${push_log}" "INFO"
  caption=""
done
