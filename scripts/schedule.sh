#!/bin/bash
#
# Standalone safe scheduler for Raspberry-NOAA-V2.
#
# This file contains both:
#   - safe, validated and atomic TLE updates; and
#   - the normal Raspberry-NOAA-V2 pass scheduling logic.
#
# Options:
#   -t  Safely update TLE data before scheduling
#   -x  Clear and rebuild future scheduled captures
#

set -Eeo pipefail

# Load Raspberry-NOAA-V2 settings and logging.
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

WEATHER_TXT="$NOAA_HOME/tmp/weather.txt"
AMATEUR_TXT="$NOAA_HOME/tmp/amateur.txt"
TLE_OUTPUT="$NOAA_HOME/tmp/orbit.tle"

TARGET_USER="${TARGET_USER:-$USER}"
SATDUMP_TLES="/home/$TARGET_USER/.config/satdump/satdump_tles.txt"

CELESTRAK_BASE="https://celestrak.org/NORAD/elements/gp.php"
WEATHER_URL="${CELESTRAK_BASE}?GROUP=weather&FORMAT=tle"
AMATEUR_URL="${CELESTRAK_BASE}?GROUP=amateur&FORMAT=tle"

update_tle=0
wipe_existing=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [-t] [-x]

  -t  Safely update TLE files
  -x  Clear and rebuild future scheduled captures
EOF
}

while getopts ":txh" opt; do
  case "$opt" in
    t) update_tle=1 ;;
    x) wipe_existing=1 ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage >&2
      exit 2
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$NOAA_HOME/tmp"
mkdir -p "$(dirname "$SATDUMP_TLES")"

cleanup_files=()
cleanup() {
  local file
  for file in "${cleanup_files[@]}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
}
trap cleanup EXIT

TEMP_FILE=""

make_temp_near() {
  local destination="$1"

  TEMP_FILE="$(mktemp "${destination}.download.XXXXXX")"
  cleanup_files+=("$TEMP_FILE")
}

download_url() {
  local url="$1"
  local destination="$2"

  rm -f -- "$destination"

  if command -v curl >/dev/null 2>&1; then
    curl \
      --fail \
      --location \
      --silent \
      --show-error \
      --retry 5 \
      --retry-delay 2 \
      --connect-timeout 20 \
      --max-time 180 \
      --output "$destination" \
      "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget \
      --quiet \
      --timeout=30 \
      --tries=5 \
      --output-document="$destination" \
      "$url"
  else
    echo "Neither curl nor wget is installed." >&2
    return 1
  fi

  # CelesTrak responses may contain CRLF line endings.
  sed -i 's/\r$//' "$destination"
}

validate_tle_structure() {
  local file="$1"
  local description="$2"
  local line1_count line2_count

  if [[ ! -s "$file" ]]; then
    echo "$description is empty." >&2
    return 1
  fi

  line1_count="$(grep -c '^1 ' "$file" || true)"
  line2_count="$(grep -c '^2 ' "$file" || true)"

  if (( line1_count == 0 || line2_count == 0 )); then
    echo "$description contains no valid TLE line pairs." >&2
    return 1
  fi

  if (( line1_count != line2_count )); then
    echo "$description has mismatched TLE lines: line 1=$line1_count, line 2=$line2_count." >&2
    return 1
  fi
}

require_catalog() {
  local file="$1"
  local catalog="$2"
  local satellite_name="$3"

  if ! grep -qE "^1[[:space:]]+${catalog}U" "$file"; then
    echo "Missing $satellite_name (NORAD $catalog) in $(basename "$file")." >&2
    return 1
  fi
}

validate_required_weather_satellites() {
  local file="$1"

  # Require only satellites enabled in the local configuration.
  if [[ "${NOAA_15_SCHEDULE:-false}" == "true" ]]; then
    require_catalog "$file" "25338" "NOAA 15" || return 1
  fi

  if [[ "${NOAA_18_SCHEDULE:-false}" == "true" ]]; then
    require_catalog "$file" "28654" "NOAA 18" || return 1
  fi

  if [[ "${NOAA_19_SCHEDULE:-false}" == "true" ]]; then
    require_catalog "$file" "33591" "NOAA 19" || return 1
  fi

  if [[ "${METEOR_M2_3_SCHEDULE:-false}" == "true" ]]; then
    require_catalog "$file" "57166" "METEOR-M2 3" || return 1
  fi

  if [[ "${METEOR_M2_4_SCHEDULE:-false}" == "true" ]]; then
    require_catalog "$file" "59051" "METEOR-M2 4" || return 1
  fi
}

append_catalog_tle() {
  local catalog="$1"
  local satellite_name="$2"
  local output="$3"
  local catalog_temp

  make_temp_near "$TLE_OUTPUT"
  catalog_temp="$TEMP_FILE"

  log "Downloading $satellite_name TLE (NORAD $catalog)" "INFO"

  if ! download_url "${CELESTRAK_BASE}?CATNR=${catalog}&FORMAT=tle" "$catalog_temp"; then
    echo "Failed downloading $satellite_name TLE." >&2
    return 1
  fi

  validate_tle_structure "$catalog_temp" "$satellite_name TLE" || return 1
  require_catalog "$catalog_temp" "$catalog" "$satellite_name" || return 1

  cat "$catalog_temp" >> "$output"
}

build_orbit_file() {
  local output="$1"

  : > "$output"

  # Keep the same satellites used by Raspberry-NOAA-V2's scheduler.
  append_catalog_tle "25338" "NOAA 15" "$output" || return 1
  append_catalog_tle "28654" "NOAA 18" "$output" || return 1
  append_catalog_tle "33591" "NOAA 19" "$output" || return 1
  append_catalog_tle "57166" "METEOR-M2 3" "$output" || return 1
  append_catalog_tle "59051" "METEOR-M2 4" "$output" || return 1

  validate_tle_structure "$output" "orbit.tle" || return 1

  require_catalog "$output" "25338" "NOAA 15" || return 1
  require_catalog "$output" "28654" "NOAA 18" || return 1
  require_catalog "$output" "33591" "NOAA 19" || return 1
  require_catalog "$output" "57166" "METEOR-M2 3" || return 1
  require_catalog "$output" "59051" "METEOR-M2 4" || return 1
}

backup_existing_file() {
  local file="$1"
  local stamp="$2"

  if [[ -e "$file" ]]; then
    cp -a -- "$file" "${file}.before-tle-update-${stamp}"
  fi
}

atomic_install() {
  local source="$1"
  local destination="$2"
  local mode="${3:-0644}"
  local staged="${destination}.install.$$"

  cleanup_files+=("$staged")
  install -m "$mode" "$source" "$staged"
  mv -f -- "$staged" "$destination"
}

safe_update_tles() {
  local weather_temp amateur_temp orbit_temp
  local stamp

  make_temp_near "$WEATHER_TXT"
  weather_temp="$TEMP_FILE"

  make_temp_near "$AMATEUR_TXT"
  amateur_temp="$TEMP_FILE"

  make_temp_near "$TLE_OUTPUT"
  orbit_temp="$TEMP_FILE"

  log "Downloading TLE files into temporary files" "INFO"

  if ! download_url "$WEATHER_URL" "$weather_temp"; then
    log "Weather TLE download failed; preserving existing files" "ERROR"
    return 1
  fi

  if ! download_url "$AMATEUR_URL" "$amateur_temp"; then
    log "Amateur TLE download failed; preserving existing files" "ERROR"
    return 1
  fi

  validate_tle_structure "$weather_temp" "Downloaded weather TLE file" || return 1
  validate_tle_structure "$amateur_temp" "Downloaded amateur TLE file" || return 1
  validate_required_weather_satellites "$weather_temp" || return 1

  if ! build_orbit_file "$orbit_temp"; then
    log "Failed building validated orbit.tle; preserving existing files" "ERROR"
    return 1
  fi

  stamp="$(date '+%Y%m%d-%H%M%S')"

  backup_existing_file "$WEATHER_TXT" "$stamp" || return 1
  backup_existing_file "$AMATEUR_TXT" "$stamp" || return 1
  backup_existing_file "$TLE_OUTPUT" "$stamp" || return 1
  backup_existing_file "$SATDUMP_TLES" "$stamp" || return 1

  # Every temporary file has passed validation. Install using atomic renames.
  atomic_install "$weather_temp" "$WEATHER_TXT" 0644 || return 1
  atomic_install "$amateur_temp" "$AMATEUR_TXT" 0644 || return 1
  atomic_install "$orbit_temp" "$TLE_OUTPUT" 0644 || return 1
  atomic_install "$weather_temp" "$SATDUMP_TLES" 0644 || return 1

  log "TLE files updated and validated successfully" "INFO"
  log "weather.txt: $(wc -c < "$WEATHER_TXT") bytes" "INFO"
  log "amateur.txt: $(wc -c < "$AMATEUR_TXT") bytes" "INFO"
  log "orbit.tle: $(wc -c < "$TLE_OUTPUT") bytes" "INFO"
}

validate_installed_tles() {
  validate_tle_structure "$WEATHER_TXT" "Installed weather.txt" || return 1
  validate_tle_structure "$AMATEUR_TXT" "Installed amateur.txt" || return 1
  validate_tle_structure "$TLE_OUTPUT" "Installed orbit.tle" || return 1
  validate_tle_structure "$SATDUMP_TLES" "Installed SatDump TLE cache" || return 1

  validate_required_weather_satellites "$WEATHER_TXT" || return 1

  require_catalog "$TLE_OUTPUT" "25338" "NOAA 15" || return 1
  require_catalog "$TLE_OUTPUT" "28654" "NOAA 18" || return 1
  require_catalog "$TLE_OUTPUT" "33591" "NOAA 19" || return 1
  require_catalog "$TLE_OUTPUT" "57166" "METEOR-M2 3" || return 1
  require_catalog "$TLE_OUTPUT" "59051" "METEOR-M2 4" || return 1
}

if (( update_tle == 1 )); then
  if ! safe_update_tles; then
    echo
    echo "TLE update failed. Existing known-good TLE files were not replaced." >&2
    echo "Scheduling has been aborted to avoid captures with invalid orbital data." >&2
    exit 1
  fi
fi

if ! validate_installed_tles; then
  echo
  echo "Local TLE data is missing, empty or invalid." >&2
  echo "Run this scheduler again with -t after network access is restored:" >&2
  if (( wipe_existing == 1 )); then
    echo "  $0 -t -x" >&2
  else
    echo "  $0 -t" >&2
  fi
  exit 1
fi

# Remove desktop-session variables that can break annotation jobs launched by at.
while IFS= read -r variable_name; do
  [[ -n "$variable_name" ]] && unset "$variable_name"
done < <(
  env |
    egrep "WAYLAND|WAYFIRE|SESSION|TERM|GIO_|DISPLAY|GPG|QT_|SAL|XDG_" |
    egrep -o '^[^=]+' || true
)

export XDG_RUNTIME_DIR="/tmp/runtime-${USER}"
mkdir -p -m 700 "$XDG_RUNTIME_DIR"

# Remove future jobs and predicted passes when -x was requested.
atq_date=""

if (( wipe_existing == 1 )); then
  log "Clearing existing scheduled 'at' capture jobs..." "INFO"

  while IFS= read -r job_id; do
    [[ -n "$job_id" ]] && atrm "$job_id"
  done < <(atq | awk '{print $1}')

  current_epoch="$(date +'%s')"
  log "Clearing future predicted passes..." "INFO"
  "$SQLITE3" "$DB_FILE" \
    "DELETE FROM predict_passes WHERE pass_start > $current_epoch;"
else
  log "Determining latest scheduled capture job date..." "INFO"
  atq_date="$(
    atq |
      sort -k 6n -k 3M -k 4n -k 5 -k 7 -k 1 |
      awk '{print $3 " " $4 ", " $6}' |
      tail -1
  )"
fi

start_time_ms="$(date +'%s')"
last_day=$((DAYS_TO_SCHEDULE_PASSES - 1))
end_time_ms="$(date --date="+${last_day} days 23:59:59" +'%s')"

if [[ -z "$atq_date" ]]; then
  log "No passes currently scheduled; scheduling through epoch ${end_time_ms}..." "INFO"
else
  latest_scheduled_ms="$(date --date="${atq_date} 23:59:59" +'%s')"
  future_schedule_ms="$(date --date="+${last_day} days 00:00:00" +'%s')"

  if (( latest_scheduled_ms >= future_schedule_ms )); then
    log "All passes are already scheduled through the configured range" "INFO"
    exit 0
  fi

  start_time_ms=$((latest_scheduled_ms + 60))
  log "Scheduling from epoch ${start_time_ms} through ${end_time_ms}..." "INFO"
fi

log "Scheduling new capture jobs..." "INFO"

schedule_satellite() {
  local satellite_name="$1"
  local receive_script="$2"

  "$NOAA_HOME/scripts/schedule_captures.sh" \
    "$satellite_name" \
    "$receive_script" \
    "$TLE_OUTPUT" \
    "$start_time_ms" \
    "$end_time_ms" \
    >> "$NOAA_LOG" 2>&1
}

if [[ "${NOAA_15_SCHEDULE:-false}" == "true" ]]; then
  log "Scheduling NOAA 15 captures..." "INFO"
  schedule_satellite "NOAA 15" "receive_noaa.sh"
fi

if [[ "${NOAA_18_SCHEDULE:-false}" == "true" ]]; then
  log "Scheduling NOAA 18 captures..." "INFO"
  schedule_satellite "NOAA 18" "receive_noaa.sh"
fi

if [[ "${NOAA_19_SCHEDULE:-false}" == "true" ]]; then
  log "Scheduling NOAA 19 captures..." "INFO"
  schedule_satellite "NOAA 19" "receive_noaa.sh"
fi

if [[ "${METEOR_M2_3_SCHEDULE:-false}" == "true" ]]; then
  log "Scheduling Meteor-M2 3 captures..." "INFO"
  schedule_satellite "METEOR-M2 3" "receive_meteor.sh"
fi

if [[ "${METEOR_M2_4_SCHEDULE:-false}" == "true" ]]; then
  log "Scheduling Meteor-M2 4 captures..." "INFO"
  schedule_satellite "METEOR-M2 4" "receive_meteor.sh"
fi

log "Done scheduling jobs!" "INFO"

if [[ "${SELECT_BEST_OVERLAPPING_PASSES:-false}" == "true" ]]; then
  log "Automatically selecting the best overlapping passes" "INFO"
  "$NOAA_HOME/scripts/select_best_overlapping_passes.py" \
    "$DB_FILE" \
    "$SELECT_METEOR_PASS_OVER_NOAA"
else
  log "Overlapping passes require manual selection" "INFO"
fi

if [[ "${ENABLE_EMAIL_SCHEDULE_PUSH:-false}" == "true" ]] && [[ ! -x "$WKHTMLTOIMG" ]]; then
  log "wkhtmltoimage is not available (removed from Debian Trixie) - skipping schedule image email" "WARN"
elif [[ "${ENABLE_EMAIL_SCHEDULE_PUSH:-false}" == "true" ]]; then
  annotation="Scheduled Passes | "

  if [[ -n "${GROUND_STATION_LOCATION:-}" ]]; then
    annotation="${annotation}Ground Station: ${GROUND_STATION_LOCATION} | "
  fi

  annotation="${annotation}Timezone: $(date '+%Z')"
  pass_image="${NOAA_HOME}/tmp/pass-list.jpg"

  log "Generating image of pass list schedule for email" "INFO"

  web_addr="http://localhost:${WEBPANEL_PORT}"
  if [[ "${ENABLE_NON_TLS:-true}" == "false" ]]; then
    web_addr="https://localhost:${WEBPANEL_TLS_PORT}"
  fi

  "$WKHTMLTOIMG" \
    --format jpg \
    --quality 100 \
    "$web_addr" \
    "$pass_image" \
    >> "$NOAA_LOG" 2>&1

  "$CONVERT" \
    "$pass_image" \
    -gravity North \
    -chop 0x190 \
    "$pass_image" \
    >> "$NOAA_LOG" 2>&1

  if [[ "${ENABLE_SATVIS:-false}" == "true" ]]; then
    "$CONVERT" \
      "$pass_image" \
      -gravity North \
      -chop 0x510 \
      "$pass_image" \
      >> "$NOAA_LOG" 2>&1
  fi

  "$PUSH_PROC_DIR/push_email.sh" \
    "$EMAIL_PUSH_ADDRESS" \
    "$pass_image" \
    "$annotation"
fi