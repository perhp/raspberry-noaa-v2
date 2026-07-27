#!/bin/bash
#
# Purpose: Build the day's mosaics and timelapses from every pass captured so
#          far. Run at the end of every capture (and from the daily summary job
#          as a fallback), so the artifacts grow through the day - each run
#          rewrites the same date-stamped files with one more pass included.
#
# Usage: daily_imagery.sh [YYYY-MM-DD]
#        Defaults to today; pass a date to rebuild an earlier day's artifacts.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

if [ "${ENABLE_DAILY_TIMELAPSE}" != "true" ] && [ "${ENABLE_DAILY_MOSAIC}" != "true" ]; then
  exit 0
fi

target_day="${1:-$(date '+%Y-%m-%d')}"
if ! day_start=$(date -d "${target_day} 00:00:00" '+%s' 2>/dev/null); then
  log "Daily imagery: '${target_day}' is not a valid date" "ERROR"
  exit 1
fi
day_end=$(date -d "${target_day} 00:00:00 + 1 day" '+%s')
day_stamp=$(date -d "${target_day}" '+%Y%m%d')

# a capture finishing while another run is in flight would otherwise have both
# writing the same outputs - wait rather than skip, so the pass that just
# finished always makes it into the result
mkdir -p "${NOAA_HOME}/tmp"
exec 9>"${NOAA_HOME}/tmp/daily_imagery.lock"
if ! flock -w 900 9; then
  log "Daily imagery: timed out waiting for another run to finish - skipping" "WARN"
  exit 0
fi

# turn an image suffix into the name used for the artifacts built from it,
# e.g. -321_projected.jpg -> 321_projected
projection_variant() {
  local variant="${1#-}"
  echo "${variant%.*}"
}

# echo the day's images for one projection suffix, one path per line, in pass
# order - optionally leaving out passes whose peak SNR fell below $2 dB, and
# night passes when $3 is true. The pass list comes from the database rather
# than from file mtimes so that a pass which finished processing after midnight
# still counts towards the day it was received, and so the SNR and daylight flag
# are available to filter on.
collect_frames() {
  local suffix="$1"
  local min_snr="$2"
  local daylight_only="$3"
  local filters=""
  local file_path

  # passes without an SNR reading are never filtered out, matching how the
  # push quality gate treats them
  if [ -n "$min_snr" ] && awk -v v="$min_snr" 'BEGIN { exit !(v + 0 > 0) }'; then
    filters="${filters} AND (max_snr IS NULL OR max_snr >= ${min_snr})"
  fi

  # opt-in: a twilight pass of a visible-light composite can still carry real
  # detail (more so at high latitudes in summer), so night passes contribute
  # their coverage by default - this exists for stations where the night frames
  # are dark enough that the brightest-pixel blend picks up their noise instead
  if [ "$daylight_only" == "true" ]; then
    filters="${filters} AND daylight_pass = 1"
  fi

  $SQLITE3 -cmd ".timeout 30000" "$DB_FILE" \
    "SELECT file_path FROM decoded_passes \
     WHERE pass_start >= ${day_start} AND pass_start < ${day_end} ${filters} \
     ORDER BY pass_start;" | while read -r file_path; do
    if [ -f "${IMAGE_OUTPUT}/${file_path}${suffix}" ]; then
      echo "${IMAGE_OUTPUT}/${file_path}${suffix}"
    fi
  done
}

# build into a hidden temp file and move it into place, so a browser loading the
# stats page mid-run never gets a partially written image. The leading dot keeps
# the temp out of the webpanel's image globs, and the name has to keep the real
# extension because ImageMagick picks the output format from it - without it a
# GIF silently comes out as a single-frame JPEG.
build_artifact() {
  local out_file="$1"
  shift

  local tmp_file
  tmp_file="$(dirname "$out_file")/.$$.$(basename "$out_file")"

  if $CONVERT "$@" "$tmp_file" >> $NOAA_LOG 2>&1 && [ -f "$tmp_file" ]; then
    mv -f "$tmp_file" "$out_file"
    return 0
  fi

  rm -f "$tmp_file"
  return 1
}

# --- timelapses, one per projection, frames in pass order ---
if [ "${ENABLE_DAILY_TIMELAPSE}" == "true" ]; then
  for timelapse_suffix in ${DAILY_TIMELAPSE_SUFFIXES}; do
    # a timelapse is a record of the day as it was received, so every pass is a
    # frame - including night ones, which simply show up dark
    mapfile -t frames < <(collect_frames "${timelapse_suffix}" 0 false)
    variant=$(projection_variant "${timelapse_suffix}")

    if [ "${#frames[@]}" -lt 2 ]; then
      log "Daily timelapse: only ${#frames[@]} frame(s) with suffix ${timelapse_suffix} on ${target_day} - skipping" "INFO"
      continue
    fi

    log "Building ${variant} timelapse from ${#frames[@]} frames" "INFO"
    if ! build_artifact "${IMAGE_OUTPUT}/timelapse-${day_stamp}-${variant}.gif" \
         -delay 80 -loop 0 "${frames[@]}" -resize 800x; then
      log "Daily timelapse: failed to build ${variant} - check $NOAA_LOG" "WARN"
    fi
  done
fi

# --- mosaics: every pass of a projection blended into one image ---
#
# SatDump renders each projection onto a fixed grid defined in its config - the
# stereographic one centred on the station, the equirectangular one covering a
# fixed window around it - so the same projection from different passes is
# already pixel-aligned and needs no warping here. Compositing with "lighten"
# keeps the brightest pixel at each position, which is the imaged swath wherever
# another frame only has empty (black) canvas.
if [ "${ENABLE_DAILY_MOSAIC}" == "true" ]; then
  for mosaic_suffix in ${DAILY_MOSAIC_SUFFIXES}; do
    mapfile -t frames < <(collect_frames "${mosaic_suffix}" "${DAILY_MOSAIC_MIN_SNR}" "${DAILY_MOSAIC_DAYLIGHT_ONLY}")
    variant=$(projection_variant "${mosaic_suffix}")

    if [ "${#frames[@]}" -lt 2 ]; then
      log "Daily mosaic: only ${#frames[@]} usable frame(s) with suffix ${mosaic_suffix} on ${target_day} - skipping" "INFO"
      continue
    fi

    log "Building ${variant} mosaic from ${#frames[@]} passes" "INFO"
    if ! build_artifact "${IMAGE_OUTPUT}/mosaic-${day_stamp}-${variant}.jpg" \
         "${frames[@]}" -background black -compose lighten -flatten; then
      log "Daily mosaic: failed to build ${variant} - check $NOAA_LOG" "WARN"
    fi
  done
fi
