#!/bin/bash
#
# Purpose: Receive and process Meteor-M 2 captures.
#
# Input parameters:
#   1. Name of satellite "METEOR-M 2"
#   2. Filename of image outputs
#   3. TLE file location
#   4. Duration of capture (seconds)
#   5. Max angle elevation for satellite
#   6. Direction of pass
#   7. Side of pass (W=West, E=East) relative to base station
#
# Example:
#   ./receive_meteor.sh "METEOR-M 2" METEOR-M220210205-192623 1612571183 922 39 Northbound W

# do not pass literal wildcard patterns to commands when a glob matches no files
shopt -s nullglob

# time keeping
TIMER_START=$(date '+%s')

# import common lib and settings
if [ ! -f "$HOME/.noaa-v2.conf" ]; then
  echo "ERROR: $HOME/.noaa-v2.conf not found - is raspberry-noaa-v2 installed?" >&2
  exit 1
fi
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"
capture_start="$START_DATE $(date '+%Z')"

# input params
if [ $# -lt 8 ]; then
  log "Expected 8 arguments but got $# - aborting: $*" "ERROR"
  exit 1
fi
export SAT_NAME=$1
export FILENAME_BASE=$2
export TLE_FILE=$3
export EPOCH_START=$4
export CAPTURE_TIME=$5
export SAT_MAX_ELEVATION=$6
export PASS_DIRECTION=$7
export PASS_SIDE=$8

if ! [[ "$EPOCH_START" =~ ^[0-9]+$ ]] || ! [[ "$CAPTURE_TIME" =~ ^[0-9]+$ ]]; then
  log "EPOCH_START ('$EPOCH_START') or CAPTURE_TIME ('$CAPTURE_TIME') is not numeric - aborting" "ERROR"
  exit 1
fi

# track the capture lifecycle in the database so the webpanel can distinguish
# in-progress processing from a failed pass; the EXIT trap catches unexpected
# deaths (config errors, crashes) so a pass never sticks in a running state
capture_status="capturing"
on_exit() {
  if [ "$capture_status" == "capturing" ] || [ "$capture_status" == "processing" ]; then
    set_pass_status "failed" "Script exited unexpectedly while ${capture_status} - check $NOAA_LOG"
  fi
}
trap on_exit EXIT
set_pass_status "capturing" ""

# base directory plus filename_base for re-use
RAMFS_AUDIO_BASE="${RAMFS_AUDIO}/${FILENAME_BASE}"
AUDIO_FILE_BASE="${METEOR_AUDIO_OUTPUT}/${FILENAME_BASE}"
IMAGE_FILE_BASE="${IMAGE_OUTPUT}/${FILENAME_BASE}"
IMAGE_THUMB_BASE="${IMAGE_OUTPUT}/thumb/${FILENAME_BASE}"

case "$RECEIVER_TYPE" in
     "rtlsdr")
         samplerate="1.024e6"
         receiver="rtlsdr"
         ;;
     "airspy_mini")
         samplerate="3e6"
         receiver="airspy"
         ;;
     "airspy_r2")
         samplerate="2.5e6"
         receiver="airspy"
         ;;
     "airspy_hf_plus_discovery")
         samplerate="192e3"
         receiver="airspy"
         ;;
     "hackrf")
         samplerate="4e6"
         receiver="hackrf"
         ;;
     "sdrplay")
         samplerate="2e6"
         receiver="sdrplay"
         ;;
     "mirisdr")
         samplerate="2e6"
         receiver="mirisdr"
         ;;
     *)
         log "Invalid RECEIVER_TYPE value: $RECEIVER_TYPE" "INFO"
         exit 1
         ;;
esac

if [ "$SAT_NAME" == "METEOR-M2 3" ]; then
  SAT_NUMBER="M2_3"
  METEOR_FREQUENCY=$METEOR_M2_3_FREQ

  # export some variables for use in downstream processing scripts - note that we do not
  # want to export all of .noaa-v2.conf because it contains sensitive info
  export GAIN=$METEOR_M2_3_GAIN
  export SUN_MIN_ELEV=$METEOR_M2_3_SUN_MIN_ELEV
  export SDR_DEVICE_ID=$METEOR_M2_3_SDR_DEVICE_ID
  export BIAS_TEE=$METEOR_M2_3_ENABLE_BIAS_TEE
  export FREQ_OFFSET=$METEOR_M2_3_FREQ_OFFSET
  export SAT_MIN_ELEV=$METEOR_M2_3_SAT_MIN_ELEV
elif [ "$SAT_NAME" == "METEOR-M2 4" ]; then
  SAT_NUMBER="M2_4"
  METEOR_FREQUENCY=$METEOR_M2_4_FREQ

  # export some variables for use in downstream processing scripts - note that we do not
  # want to export all of .noaa-v2.conf because it contains sensitive info
  export GAIN=$METEOR_M2_4_GAIN
  export SUN_MIN_ELEV=$METEOR_M2_4_SUN_MIN_ELEV
  export SDR_DEVICE_ID=$METEOR_M2_4_SDR_DEVICE_ID
  export BIAS_TEE=$METEOR_M2_4_ENABLE_BIAS_TEE
  export FREQ_OFFSET=$METEOR_M2_4_FREQ_OFFSET
  export SAT_MIN_ELEV=$METEOR_M2_4_SAT_MIN_ELEV
else
  log "Unknown Meteor satellite name: '$SAT_NAME' - no gain/frequency settings exist for it, aborting" "ERROR"
  exit 1
fi

interleaving="METEOR_${SAT_NUMBER}_80K_INTERLEAVING"
mode="$([[ "${!interleaving}" == "true" ]] && echo "_80k" || echo "")"

if [[ "$receiver" == "rtlsdr" ]]; then
  gain_option="--gain"
  ppm_correction="--ppm_correction"
else
  gain_option="--general_gain"
  FREQ_OFFSET=""
fi

if [[ "$USE_DEVICE_STRING" == "true" ]]; then
  sdr_id_option="--source_id"
else
  sdr_id_option=""
  SDR_DEVICE_ID=""
fi

if [ "$BIAS_TEE" == "-T" ]; then
    bias_tee_option="--bias"
else
    bias_tee_option=""
fi

# check if there is enough free memory to store pass on RAM
# (default to 0 if 'free' output could not be parsed so we fall back to SD storage)
FREE_MEMORY=$(free -m | grep Mem | awk '{print $7}')
FREE_MEMORY=${FREE_MEMORY:-0}
METEOR_M2_MEMORY_THRESHOLD=${METEOR_M2_MEMORY_THRESHOLD:-50}
if [ "$FREE_MEMORY" -lt "$METEOR_M2_MEMORY_THRESHOLD" ]; then
  log "The system doesn't have enough space to store a Meteor pass on RAM" "INFO"
  log "Free : ${FREE_MEMORY} ; Required : ${METEOR_M2_MEMORY_THRESHOLD}" "INFO"
  RAMFS_AUDIO_BASE="${AUDIO_FILE_BASE}"
  in_mem=false
else
  log "The system has enough space to store a Meteor pass on RAM" "INFO"
  log "Free : ${FREE_MEMORY} ; Required : ${METEOR_M2_MEMORY_THRESHOLD}" "INFO"
  in_mem=true
fi

FLIP=""
log "Direction $PASS_DIRECTION" "INFO"
if [ "$PASS_DIRECTION" == "Northbound" ] && [ "$FLIP_METEOR_IMG" == "true" ]; then
  log "I'll flip this image pass because FLIP_METEOR_IMG is set to true and PASS_DIRECTION is Northbound" "INFO"
  FLIP="-rotate 180"
fi

# pass start timestamp and sun elevation
PASS_START=$((EPOCH_START + 90))
export SUN_ELEV=$("$PYTHON" "$SCRIPTS_DIR"/tools/sun.py "$PASS_START")
if ! [[ "$SUN_ELEV" =~ ^-?[0-9]+$ ]]; then
  log "Could not determine sun elevation (got '$SUN_ELEV') - defaulting to 0" "ERROR"
  export SUN_ELEV=0
fi

# determine if pass is in daylight
daylight=0
if [ "${SUN_ELEV}" -gt "${SUN_MIN_ELEV:-0}" ]; then daylight=1; fi

push_file_list=""
spectrogram=0
polar_az_el=0
polar_direction=0

#---------------------------------------------------------------------------------------------------------------------------------------------------------------------

log "Recording ${NOAA_HOME} via $receiver at ${METEOR_FREQUENCY} MHz using SatDump record " "INFO"
# NOTE: RAMFS_FILE_BASE is intentionally undefined, so this resolves to "." -
# SatDump then writes its decode output (the MSU-MR directories) into the
# current working directory, which is where the processing below expects to
# find them. Do not "fix" this without also changing those paths.
audio_temporary_storage_directory="$(dirname "${RAMFS_FILE_BASE}")"
log "$SATDUMP live meteor_m2-x_lrpt${mode} $audio_temporary_storage_directory --source $receiver --samplerate $samplerate $ppm_correction ${FREQ_OFFSET} --frequency ${METEOR_FREQUENCY}e6 $sdr_id_option $SDR_DEVICE_ID $gain_option $GAIN $bias_tee_option --finish_processing --fill_missing --timeout $CAPTURE_TIME" "INFO"
# wrap SatDump in a watchdog timeout so a hung SDR/capture cannot block the
# scheduler forever and eat subsequent passes - allow generous extra time
# beyond the capture itself for --finish_processing to decode the images
timeout --kill-after=60 $((CAPTURE_TIME + 900)) $SATDUMP live meteor_m2-x_lrpt${mode} "$audio_temporary_storage_directory" --source $receiver --samplerate $samplerate $ppm_correction ${FREQ_OFFSET} --frequency "${METEOR_FREQUENCY}e6" $sdr_id_option $SDR_DEVICE_ID $gain_option $GAIN $bias_tee_option --finish_processing --fill_missing --timeout $CAPTURE_TIME >> $NOAA_LOG 2>&1
satdump_rc=$?
if [ $satdump_rc -ne 0 ]; then
  log "SatDump exited with code ${satdump_rc} (124 = watchdog timeout) - continuing with whatever was produced" "ERROR"
fi

cadu_produced=true
if [ -f "$audio_temporary_storage_directory/meteor_m2-x_lrpt${mode}.cadu" ]; then
  mv "$audio_temporary_storage_directory/meteor_m2-x_lrpt${mode}.cadu" "${RAMFS_AUDIO_BASE}.cadu" >> $NOAA_LOG 2>&1
else
  cadu_produced=false
  log "SatDump did not produce a CADU file - capture likely failed (no signal, SDR busy or unplugged?)" "ERROR"
fi
capture_status="processing"
set_pass_status "processing" ""

# make sure the working directory exists even if SatDump failed to decode
# anything, so none of the processing below errors out on a missing directory
mkdir -p "MSU-MR (Filled)"

# newer SatDump versions can place generated composites in MSU-MR while
# raspberry-noaa-v2 expects to process them from MSU-MR (Filled); copy them
# over WITHOUT clobbering (-n) so gap-filled versions are never overwritten
# by their unfilled counterparts
if [ -d "MSU-MR" ]; then
  find "MSU-MR" -maxdepth 1 -type f \
    \( -name "*_corrected.png" -o -name "*_projected.png" \) \
    -exec cp -n {} "MSU-MR (Filled)/" \; >> $NOAA_LOG 2>&1
fi

# keep the corrected/projected composites plus the raw MSU-MR channel images (MSU-MR-1..6)
find "MSU-MR (Filled)/" -type f ! -name "*projected*" ! -name "*corrected*" ! -name "MSU-MR-*" -delete

log "Deleting SatDump projected composites which have been generated, but the channels aren't broadcast" "INFO"
for projected_file in MSU-MR\ \(Filled\)/rgb_msu_mr_rgb_*_projected.png; do
    # Extract the corresponding corrected.png filename
    corrected_file="${projected_file/rgb_msu_mr_rgb_/msu_mr_rgb_}"
    corrected_file="${corrected_file/_projected.png/_corrected.png}"

    # Check if the corrected.png file does not exist
    if [ ! -e "$corrected_file" ]; then
        log "$corrected_file doesn't exist, hence deleting $projected_file" "INFO"
        rm "$projected_file"
    fi
done

# the equirectangular composite variants only exist for their projected output - their
# corrected images are identical to the base composite's, so drop the duplicates
log "Removing duplicate corrected images from equirectangular composite variants" "INFO"
rm -f MSU-MR\ \(Filled\)/*_equirect_corrected.png >> $NOAA_LOG 2>&1

log "Removing images without a map if they exist" "INFO"
for file in MSU-MR\ \(Filled\)/*map.png; do
  mv "$file" "${file/_map.png/.png}"
done

log "Flipping Meteor night passes decoded with SatDump" "INFO"
for i in MSU-MR\ \(Filled\)/*_corrected.png MSU-MR\ \(Filled\)/MSU-MR-*.png; do
  $CONVERT "$i" $FLIP "$i" >> $NOAA_LOG 2>&1
done

  # Renaming files, normalizing images, and creating thumbnails
for i in MSU-MR\ \(Filled\)/*.png; do
  path="$(pwd)"
  image_filename=$(basename "$i")
  new_name="$image_filename"

  # Use parameter expansion to remove the specified prefixes
  new_name="${new_name#msu_mr_rgb_}"
  new_name="${new_name#rgb_msu_mr_rgb_}"
  new_name="${new_name#rgb_msu_mr_rgb_}"
  new_name="${new_name#rgb_msu_mr_}"
  new_name="${new_name#msu_mr_}"

  # Rename the file with the new name (skip when no prefix was stripped,
  # e.g. the raw MSU-MR-N channel images, to avoid same-file mv errors)
  if [ "$image_filename" != "$new_name" ]; then
    mv "$i" "$path/MSU-MR (Filled)/$new_name" >> $NOAA_LOG 2>&1
  fi

  log "Normalizing images and creating thumbnails" "INFO"
  ${IMAGE_PROC_DIR}/meteor_normalize.sh "$path/MSU-MR (Filled)/$new_name" "${IMAGE_FILE_BASE}-${new_name%.png}.jpg" $METEOR_IMAGE_QUALITY >> $NOAA_LOG 2>&1
  ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-${new_name%.png}.jpg" "${IMAGE_THUMB_BASE}-${new_name%.png}.jpg" >> $NOAA_LOG 2>&1
  rm "$path/MSU-MR (Filled)/$new_name" >> $NOAA_LOG 2>&1
  push_file_list="$push_file_list ${IMAGE_FILE_BASE}-${new_name%.png}.jpg"
done
rm -rf "MSU-MR (Filled)" >> $NOAA_LOG 2>&1
rm -rf "MSU-MR" >> $NOAA_LOG 2>&1

if [ "${CONTRIBUTE_TO_COMMUNITY_COMPOSITES}" == "true" ] && [ -f "${RAMFS_AUDIO_BASE}.cadu" ]; then
  log "Contributing images for creating community composites" "INFO"
  curl -F "file=@${RAMFS_AUDIO_BASE}.cadu" "${CONTRIBUTE_TO_COMMUNITY_COMPOSITES_URL}/meteor" >> $NOAA_LOG 2>&1
fi

if [ "$DELETE_METEOR_AUDIO" == true ]; then
  log "Deleting audio files" "INFO"
  rm -f "${RAMFS_AUDIO_BASE}.cadu" >> $NOAA_LOG 2>&1
else
  if [ "$in_mem" == "true" ] && [ -f "${RAMFS_AUDIO_BASE}.cadu" ]; then
    log "Moving CADU files out to the SD card" "INFO"
    mv "${RAMFS_AUDIO_BASE}.cadu" "${AUDIO_FILE_BASE}.cadu" >> $NOAA_LOG 2>&1
    log "Deleting Meteor audio files older than ${DELETE_FILES_OLDER_THAN_DAYS:-3} days" "INFO"
    find "${METEOR_AUDIO_OUTPUT}" -type f \( -name "*.wav" -o -name "*.s" -o -name "*.cadu" -o -name "*.gcp" -o -name "*.dat" -o -name "*.bmp" \) -mtime +${DELETE_FILES_OLDER_THAN_DAYS:-3} -delete >> $NOAA_LOG 2>&1
  fi
fi

#---------------------------------------------------------------------------------------------------------------------------------------------------------------------

if [ -n "$(find "${IMAGE_OUTPUT}" -maxdepth 1 -type f -name "$(basename "$IMAGE_FILE_BASE")*.jpg" -print -quit)" ]; then

  # determine if auto-gain is set - handles "0" and "0.0" floats
  gain=${GAIN:-0}
  if [ "$(echo "${GAIN:-0}==0" | bc 2>/dev/null)" == "1" ]; then
    gain='Automatic'
  fi

  # create push annotation string (annotation in the email subject, discord text, etc.)
  push_annotation=""
  if [ "${GROUND_STATION_LOCATION}" != "" ]; then
    push_annotation="Ground Station: ${GROUND_STATION_LOCATION}"
  fi
  push_annotation="${push_annotation} ${SAT_NAME} ${capture_start} "
  push_annotation="${push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}"
  push_annotation="${push_annotation} Sun Elevation: ${SUN_ELEV}°"
  push_annotation="${push_annotation} Gain: ${gain}"
  push_annotation="${push_annotation} | ${PASS_DIRECTION}"

  meteor_suffixes=(
      '-MSA_corrected.jpg'
      '-MSA_projected.jpg'
      '-Natural_Color_corrected.jpg'
      '-Natural_Color_projected.jpg'
      '-MCIR_corrected.jpg'
      '-MCIR_projected.jpg'
      '-321_corrected.jpg'
      '-321_projected.jpg'
      '-221_corrected.jpg'
      '-221_projected.jpg'
      '-Day_Microphysics_corrected.jpg'
      '-Night_Microphysics_corrected.jpg'
      '-124_corrected.jpg'
      '-456_corrected.jpg'
      '-654_corrected.jpg'
      '-39um_Shortwave_IR_corrected.jpg'
      '-39um_Shortwave_IR_Calibrated_corrected.jpg'
      '-Thermal_Channel_corrected.jpg'
  )

  # Iterate through the meteor_suffixes array
  website_suffix=""
  for suffix in "${meteor_suffixes[@]}"; do
      if [[ -f "${IMAGE_THUMB_BASE}${suffix}" ]]; then
          cp "${IMAGE_THUMB_BASE}${suffix}" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg" >> $NOAA_LOG 2>&1
          website_suffix="$suffix"
          break
      fi
  done

  log "Some images were produced, let's push them to the database and social media" "INFO"
  if [[ "${PRODUCE_POLAR_AZ_EL}" == "true" ]]; then
    log "Producing polar graph of azimuth and elevation for pass" "INFO"
    polar_az_el=1
    epoch_end=$((EPOCH_START + CAPTURE_TIME))
    "$PYTHON" ${IMAGE_PROC_DIR}/polar_plot.py "${SAT_NAME}" \
                                            "${TLE_FILE}" \
                                            $EPOCH_START \
                                            $epoch_end \
                                            $LAT \
                                            $LON \
                                            $SAT_MIN_ELEV \
                                            $PASS_DIRECTION \
                                            "${IMAGE_FILE_BASE}-polar-azel.jpg" \
                                            "azel" >> $NOAA_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-polar-azel.jpg" "${IMAGE_THUMB_BASE}-polar-azel.jpg" >> $NOAA_LOG 2>&1
  fi

  polar_direction=0
  if [[ "${PRODUCE_POLAR_DIRECTION}" == "true" ]]; then
    log "Producing polar graph of direction for pass" "INFO"
    polar_direction=1
    epoch_end=$((EPOCH_START + CAPTURE_TIME))
    "$PYTHON" ${IMAGE_PROC_DIR}/polar_plot.py "${SAT_NAME}" \
                                            "${TLE_FILE}" \
                                            $EPOCH_START \
                                            $epoch_end \
                                            $LAT \
                                            $LON \
                                            $SAT_MIN_ELEV \
                                            $PASS_DIRECTION \
                                            "${IMAGE_FILE_BASE}-polar-direction.png" \
                                            "direction" >> $NOAA_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-polar-direction.png" "${IMAGE_THUMB_BASE}-polar-direction.png" >> $NOAA_LOG 2>&1
  fi

  # check if we got an image, and post-process if so

  log "I got a successful jpg images" "INFO"

  # insert or replace in case there was already an insert due to the spectrogram creation
  # (use a busy timeout on all database access so a webpanel read can't fail the insert)
  $SQLITE3 -cmd ".timeout 30000" $DB_FILE "INSERT OR REPLACE INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, has_spectrogram, has_polar_az_el, has_polar_direction, gain) \
                                      VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 0, $spectrogram, $polar_az_el, $polar_direction, ${GAIN:-0});" >> $NOAA_LOG 2>&1

  pass_id=$($SQLITE3 -cmd ".timeout 30000" $DB_FILE "SELECT id FROM decoded_passes ORDER BY id DESC LIMIT 1;")
  $SQLITE3 -cmd ".timeout 30000" $DB_FILE "UPDATE predict_passes \
                    SET is_active = 0 \
                    WHERE (predict_passes.pass_start) \
                    IN ( \
                      SELECT predict_passes.pass_start \
                      FROM predict_passes \
                      INNER JOIN decoded_passes \
                      ON predict_passes.pass_start = decoded_passes.pass_start \
                      WHERE decoded_passes.id = $pass_id \
                    );" >> $NOAA_LOG 2>&1

  capture_status="received"
  set_pass_status "received" ""

  # handle Pushover pushing if enabled
  if [ "${ENABLE_PUSHOVER_PUSH}" == "true" ]; then
    pushover_push_annotation=""
    #if [ "${GROUND_STATION_LOCATION}" != "" ]; then
    #  pushover_push_annotation="Ground Station: ${GROUND_STATION_LOCATION}<br/>"
    #fi
    pushover_push_annotation="${pushover_push_annotation}<b>Start: </b>${capture_start}<br/>"
    pushover_push_annotation="${pushover_push_annotation}<b>Max Elev: </b>${SAT_MAX_ELEVATION}° ${PASS_SIDE}<br/>"
    #pushover_push_annotation="${pushover_push_annotation}<b>Sun Elevation: </b>${SUN_ELEV}°<br/>"
    #pushover_push_annotation="${pushover_push_annotation}<b>Gain: </b>${gain} | ${PASS_DIRECTION}<br/>"
    pushover_push_annotation="${pushover_push_annotation} <a href=${PUSHOVER_LINK_URL}?pass_id=${pass_id}>BROWSER LINK</a>";

    log "Call pushover script with push_file_list: $push_file_list" "INFO"
    ${PUSH_PROC_DIR}/push_pushover.sh "${pushover_push_annotation}" "${SAT_NAME}" "$push_file_list" >> $NOAA_LOG 2>&1
  fi

  # handle Slack pushing if enabled
  if [ "${ENABLE_SLACK_PUSH}" == "true" ]; then
    ${PUSH_PROC_DIR}/push_slack.sh "${push_annotation} <${SLACK_LINK}?pass_id=${pass_id}>\n" $push_file_list >> $NOAA_LOG 2>&1
  fi

  # handle Twitter pushing if enabled
  if [ "${ENABLE_TWITTER_PUSH}" == "true" ]; then
    log "Pushing image enhancements to Twitter" "INFO"
    ${PUSH_PROC_DIR}/push_twitter.sh "${push_annotation}" $push_file_list >> $NOAA_LOG 2>&1
  fi

  # handle Facebook pushing if enabled
  if [ "${ENABLE_FACEBOOK_PUSH}" == "true" ]; then
    log "Pushing image enhancements to Facebook" "INFO"
    "$PYTHON" ${PUSH_PROC_DIR}/push_facebook.py "${push_annotation}" "${push_file_list}" >> $NOAA_LOG 2>&1
  fi

  # handle Mastodon pushing if enabled
  if [ "${ENABLE_MASTODON_PUSH}" == "true" ]; then
    log "Pushing image enhancements to Mastodon" "INFO"
    "$PYTHON" ${PUSH_PROC_DIR}/push_mastodon.py "${push_annotation}" ${push_file_list} >> $NOAA_LOG 2>&1
  fi

  # handle Bluesky pushing if enabled
  if [ "${ENABLE_BLUESKY_PUSH}" == "true" ]; then
    log "Pushing image enhancements to Bluesky" "INFO"
    "$PYTHON" ${PUSH_PROC_DIR}/push_bluesky.py "${push_annotation}" ${push_file_list} >> $NOAA_LOG 2>&1
  fi

  # handle Instagram pushing if enabled
  if [ "${ENABLE_INSTAGRAM_PUSH}" == "true" ]; then
    if [ -n "$website_suffix" ] && [ -f "${IMAGE_FILE_BASE}${website_suffix}" ]; then
      log "Pushing image enhancements to Instagram" "INFO"
      $CONVERT "${IMAGE_FILE_BASE}${website_suffix}" -resize "1080x1350>" -gravity center -background black -extent 1080x1350 "${IMAGE_FILE_BASE}-instagram.jpg" >> $NOAA_LOG 2>&1
      "$PYTHON" ${PUSH_PROC_DIR}/push_instagram.py "${push_annotation}" $(sed "s|${IMAGE_OUTPUT}/||" <<< "${IMAGE_FILE_BASE}-instagram.jpg") ${WEB_SERVER_NAME} >> $NOAA_LOG 2>&1
      rm -f "${IMAGE_FILE_BASE}-instagram.jpg"
    else
      log "Skipping Instagram push - no suitable source image found" "INFO"
    fi
  fi

  # handle Matrix pushing if enabled
  if [ "${ENABLE_MATRIX_PUSH}" == "true" ]; then
    log "Pushing image enhancements to Matrix" "INFO"
    ${PUSH_PROC_DIR}/push_matrix.sh "${push_annotation}" $push_file_list >> $NOAA_LOG 2>&1
  fi

  # handle Telegram pushing if enabled
  if [ "${ENABLE_TELEGRAM_PUSH}" == "true" ]; then
    log "Pushing image enhancements to Telegram" "INFO"
    ${PUSH_PROC_DIR}/push_telegram.sh "${push_annotation}" $push_file_list >> $NOAA_LOG 2>&1
  fi

  # handle generic webhook pushing if enabled
  if [ "${ENABLE_WEBHOOK_PUSH}" == "true" ]; then
    log "Pushing capture event to webhook" "INFO"
    ${PUSH_PROC_DIR}/push_webhook.sh "${pass_id}" "${daylight}" $push_file_list >> $NOAA_LOG 2>&1
  fi

  # handle email pushing if enabled
  if [ "$ENABLE_EMAIL_PUSH" == "true" ]; then
    log "Emailing images" "INFO"
    for i in $push_file_list
    do
      ${PUSH_PROC_DIR}/push_email.sh "${EMAIL_PUSH_ADDRESS}" "$i" "${push_annotation}" >> $NOAA_LOG 2>&1
    done
  fi

  # handle Discord pushing if enabled
  if [ "${ENABLE_DISCORD_PUSH}" == "true" ]; then
    log "Pushing images to Discord" "INFO"
    for i in $push_file_list
    do
      ${PUSH_PROC_DIR}/push_discord.sh "$DISCORD_METEOR_WEBHOOK" "$i" "${push_annotation}" >> $NOAA_LOG 2>&1
    done
  fi
else
  log "No images found, not pushing anything" "INFO"
  capture_status="failed"
  if [ "$cadu_produced" == "false" ]; then
    failure_reason="Recording produced no CADU data (no signal, SDR busy or unplugged?)"
  else
    failure_reason="Decoder produced no images from the recording - check $NOAA_LOG"
  fi
  if [ $satdump_rc -ne 0 ]; then
    failure_reason="${failure_reason} (SatDump exit code ${satdump_rc}, 124 = watchdog timeout)"
  fi
  set_pass_status "failed" "$failure_reason"
fi

# calculate and report total time for capture
TIMER_END=$(date '+%s')
DIFF=$(($TIMER_END - $TIMER_START))
PROC_TIME=$(date -ud "@$DIFF" +'%H:%M.%S')
log "Total processing time: ${PROC_TIME}" "INFO"