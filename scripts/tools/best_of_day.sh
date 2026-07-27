#!/bin/bash
#
# Purpose: Once a day (evening cron), pick the best capture of the day -
#          ranked by peak SNR, falling back to max elevation - and push a
#          single summary post through the enabled push channels. Optionally
#          also assembles an animated timelapse GIF from the day's Meteor
#          projections, and mosaics that blend every pass of a given projection
#          into one wide-coverage image, attaching both.
#
# This complements (or replaces) per-pass pushing: users who find per-pass
# posts too noisy can disable those and enable only this daily summary.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

if [ "${ENABLE_BEST_OF_DAY_PUSH}" != "true" ] && [ "${ENABLE_DAILY_TIMELAPSE}" != "true" ] && \
   [ "${ENABLE_DAILY_MOSAIC}" != "true" ]; then
  exit 0
fi

today=$(date '+%Y-%m-%d')
day_start=$(date -d "${today} 00:00:00" '+%s')
day_end=$(date -d "${today} 00:00:00 + 1 day" '+%s')

# echo the day's images for one projection suffix, one path per line, in pass
# order - optionally leaving out passes whose peak SNR fell below $2 dB, and
# night passes when $3 is true. The pass list comes from the database rather
# than from file mtimes so that a pass which finished processing after midnight
# still counts towards the day it was received, and so the SNR and daylight flag
# are available to filter on.
# turn an image suffix into the name used for the artifacts built from it,
# e.g. -321_projected.jpg -> 321_projected
projection_variant() {
  local variant="${1#-}"
  echo "${variant%.*}"
}

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

push_file_list=""
annotation="Daily summary ${today}"
if [ -n "${GROUND_STATION_LOCATION}" ]; then
  annotation="${annotation} - ${GROUND_STATION_LOCATION}"
fi

# --- best capture of the day ---
if [ "${ENABLE_BEST_OF_DAY_PUSH}" == "true" ]; then
  best_row=$($SQLITE3 -cmd ".timeout 30000" -separator '|' "$DB_FILE" \
    "SELECT d.file_path, p.sat_name, p.max_elev, IFNULL(d.max_snr, ''), d.daylight_pass, d.sat_type \
     FROM decoded_passes d \
     INNER JOIN predict_passes p ON p.pass_start = d.pass_start \
     WHERE d.pass_start >= ${day_start} \
     ORDER BY (d.max_snr IS NULL) ASC, d.max_snr DESC, p.max_elev DESC \
     LIMIT 1;")

  if [ -z "$best_row" ]; then
    log "Best of day: no captures today - nothing to pick" "INFO"
  else
    IFS='|' read -r file_path sat_name max_elev max_snr daylight sat_type <<< "$best_row"

    # pick a representative enhancement, preferring the composites the
    # gallery also leads with, falling back to any non-graph image
    if [ "$sat_type" == "1" ]; then
      if [ "$daylight" == "1" ]; then
        candidates=("-MSA.jpg" "-MSA-precip.jpg" "-HVC.jpg" "-MCIR.jpg")
      else
        candidates=("-MCIR.jpg" "-MCIR-precip.jpg" "-therm.jpg" "-HVCT.jpg")
      fi
    else
      candidates=("-MSA_corrected.jpg" "-Natural_Color_corrected.jpg" "-321_corrected.jpg" "-221_corrected.jpg" "-MCIR_corrected.jpg" "-Night_Microphysics_corrected.jpg" "-654_corrected.jpg")
    fi

    best_image=""
    for suffix in "${candidates[@]}"; do
      if [ -f "${IMAGE_OUTPUT}/${file_path}${suffix}" ]; then
        best_image="${IMAGE_OUTPUT}/${file_path}${suffix}"
        break
      fi
    done
    if [ -z "$best_image" ]; then
      best_image=$(find "${IMAGE_OUTPUT}" -maxdepth 1 -type f -name "${file_path}-*.jpg" ! -name "*polar*" | sort | head -1)
    fi

    if [ -n "$best_image" ]; then
      annotation="${annotation} | Best capture: ${sat_name}, max elev ${max_elev}°"
      if [ -n "$max_snr" ]; then
        annotation="${annotation}, peak SNR ${max_snr} dB"
      fi
      push_file_list="${best_image}"
      log "Best of day: ${best_image} (${sat_name}, ${max_elev}°, SNR ${max_snr:-n/a})" "INFO"
    else
      log "Best of day: no image found on disk for ${file_path}" "WARN"
    fi
  fi
fi

# --- daily timelapses, one per projection, frames in pass order ---
if [ "${ENABLE_DAILY_TIMELAPSE}" == "true" ]; then
  for timelapse_suffix in ${DAILY_TIMELAPSE_SUFFIXES}; do
    # a timelapse is a record of the day as it was received, so every pass is a
    # frame - including night ones, which simply show up dark
    mapfile -t frames < <(collect_frames "${timelapse_suffix}" 0 false)
    variant=$(projection_variant "${timelapse_suffix}")

    if [ "${#frames[@]}" -lt 2 ]; then
      log "Daily timelapse: only ${#frames[@]} frame(s) with suffix ${timelapse_suffix} today - skipping" "INFO"
      continue
    fi

    timelapse="${IMAGE_OUTPUT}/timelapse-$(date '+%Y%m%d')-${variant}.gif"
    log "Building daily ${variant} timelapse from ${#frames[@]} frames" "INFO"
    $CONVERT -delay 80 -loop 0 "${frames[@]}" -resize 800x "$timelapse" >> $NOAA_LOG 2>&1
    if [ -f "$timelapse" ]; then
      push_file_list="${push_file_list} ${timelapse}"
      annotation="${annotation} | Timelapse ${variant}: ${#frames[@]} passes"
    else
      log "Daily timelapse: failed to build ${timelapse}" "WARN"
    fi
  done
fi

# --- daily mosaics: every pass of a projection blended into one image ---
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
      log "Daily mosaic: only ${#frames[@]} usable frame(s) with suffix ${mosaic_suffix} today - skipping" "INFO"
      continue
    fi

    mosaic="${IMAGE_OUTPUT}/mosaic-$(date '+%Y%m%d')-${variant}.jpg"
    log "Building daily ${variant} mosaic from ${#frames[@]} passes" "INFO"
    $CONVERT "${frames[@]}" -background black -compose lighten -flatten "$mosaic" >> $NOAA_LOG 2>&1
    if [ -f "$mosaic" ]; then
      push_file_list="${push_file_list} ${mosaic}"
      annotation="${annotation} | Mosaic ${variant}: ${#frames[@]} passes"
    else
      log "Daily mosaic: failed to build ${mosaic}" "WARN"
    fi
  done
fi

if [ -z "$push_file_list" ]; then
  log "Best of day: nothing to push" "INFO"
  exit 0
fi

# --- push through the enabled channels ---
if [ "${ENABLE_TELEGRAM_PUSH}" == "true" ]; then
  ${PUSH_PROC_DIR}/push_telegram.sh "${annotation}" $push_file_list >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_DISCORD_PUSH}" == "true" ]; then
  for i in $push_file_list; do
    ${PUSH_PROC_DIR}/push_discord.sh "$DISCORD_NOAA_WEBHOOK" "$i" "${annotation}" >> $NOAA_LOG 2>&1
  done
fi

if [ "${ENABLE_PUSHOVER_PUSH}" == "true" ]; then
  ${PUSH_PROC_DIR}/push_pushover.sh "${annotation}" "Best of day" "$push_file_list" >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_SLACK_PUSH}" == "true" ]; then
  ${PUSH_PROC_DIR}/push_slack.sh "${annotation}" >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_MATRIX_PUSH}" == "true" ]; then
  ${PUSH_PROC_DIR}/push_matrix.sh "${annotation}" $push_file_list >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_MASTODON_PUSH}" == "true" ]; then
  "$PYTHON" ${PUSH_PROC_DIR}/push_mastodon.py "${annotation}" $push_file_list >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_BLUESKY_PUSH}" == "true" ]; then
  "$PYTHON" ${PUSH_PROC_DIR}/push_bluesky.py "${annotation}" $push_file_list >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_TWITTER_PUSH}" == "true" ]; then
  ${PUSH_PROC_DIR}/push_twitter.sh "${annotation}" $push_file_list >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_FACEBOOK_PUSH}" == "true" ]; then
  "$PYTHON" ${PUSH_PROC_DIR}/push_facebook.py "${annotation}" "${push_file_list}" >> $NOAA_LOG 2>&1
fi

if [ "${ENABLE_EMAIL_PUSH}" == "true" ]; then
  for i in $push_file_list; do
    ${PUSH_PROC_DIR}/push_email.sh "${EMAIL_PUSH_ADDRESS}" "$i" "${annotation}" >> $NOAA_LOG 2>&1
  done
fi

log "Best of day push complete" "INFO"
