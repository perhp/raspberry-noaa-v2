#!/bin/bash
#
# Purpose: Common code that is likely loaded in most of the scripts
#          within this framework. Handles things such as a start date/time,
#          logging, and other various "common" functionality.

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
log_level=${LOG_LEVEL}

# log function
log() {
  local log_message=$1
  local log_priority=$2

  # check if level exists and is of the right level to log
  [[ ${levels[$log_priority]} ]] || return 1
  (( ${levels[$log_priority]} < ${levels[$log_level]} )) && return 2

  # log in place (which for at jobs end up in the linux mail)
  echo "${log_priority} : ${log_message}"

  # log output to a log file
  echo $(date '+%d-%m-%Y %H:%M') $0 "${log_priority} : ${log_message}" >> "$NOAA_LOG"
}

# run as a normal user for any scripts within
if [ $EUID -eq 0 ]; then
  log "This script shouldn't be run as root." "ERROR"
  exit 1
fi

# binary helpers
CONVERT="/usr/bin/convert"
FFMPEG="/usr/bin/ffmpeg"
SOX="/usr/bin/sox"
GMIC="/usr/bin/gmic"
IDENTIFY="/usr/bin/identify"
RTL_FM="/usr/local/bin/rtl_fm"
SQLITE3="/usr/bin/sqlite3"
WKHTMLTOIMG="/usr/bin/wkhtmltoimage"
METEORDEMOD="/usr/local/bin/meteordemod"
SATDUMP="/usr/bin/satdump"

# Python interpreter - ~/.noaa-v2.conf points this at the RN2 virtualenv,
# which contains the pip-only packages (envbash, facebook-sdk) on top of the
# system site-packages; fall back to the system interpreter on installs that
# predate the virtualenv
PYTHON="${PYTHON:-/usr/bin/python3}"

# record capture lifecycle status ('capturing', 'processing', 'received',
# 'failed') on the scheduled pass row so the webpanel can show real state
# instead of inferring it from timestamps; non-fatal if the database predates
# the status columns (the failed update only lands in the log)
set_pass_status() {
  local status=$1
  local error_text=$2
  [ -z "$EPOCH_START" ] && return 0
  local safe_error=${error_text//"'"/"''"}
  $SQLITE3 -cmd ".timeout 30000" "$DB_FILE" \
    "UPDATE predict_passes SET status = '${status}', error_text = '${safe_error}' WHERE pass_start = $EPOCH_START;" >> "$NOAA_LOG" 2>&1
}

# base directories for scripts
SCRIPTS_DIR="${NOAA_HOME}/scripts"
AUDIO_PROC_DIR="${SCRIPTS_DIR}/audio_processors"
IMAGE_PROC_DIR="${SCRIPTS_DIR}/image_processors"
PUSH_PROC_DIR="${SCRIPTS_DIR}/push_processors"

# frequency ranges for objects
METEOR_M2_3_FREQ="137.9000"
METEOR_M2_4_FREQ="137.9000"
NOAA15_FREQ="137.6200"
NOAA18_FREQ="137.9125"
NOAA19_FREQ="137.1000"
ELEKTRO_L3_FREQ="1691.0000"

# current date and time
export START_DATE=$(date '+%d-%m-%Y %H:%M')
