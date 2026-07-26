#!/bin/bash
#
# Purpose: Create an "at" scheduled job for capture based on the following
#          input parameter positions:
#            1. Satellite Name
#            2. Name of script to call for reception
#            3. TLE file
#            4. Start time to predict passes (epoch seconds)
#            5. End time to predict passes (epoch seconds)
#
# Example:
#   ./schedule_captures.sh "NOAA 18" "receive_noaa.sh" "orbit.tle" 1617422399 1617425300

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

# map inputs to sane var names
OBJ_NAME=$1
RECEIVE_SCRIPT=$2
TLE_FILE=$3
START_TIME_MS=$4
END_TIME_MS=$5

if [ "$OBJ_NAME" == "NOAA 15" ]; then
  SAT_MIN_ELEV=$NOAA_15_SAT_MIN_ELEV
fi
if [ "$OBJ_NAME" == "NOAA 18" ]; then
  SAT_MIN_ELEV=$NOAA_18_SAT_MIN_ELEV
fi
if [ "$OBJ_NAME" == "NOAA 19" ]; then
  SAT_MIN_ELEV=$NOAA_19_SAT_MIN_ELEV
fi
if [ "$OBJ_NAME" == "METEOR-M2 3" ]; then
  SAT_MIN_ELEV=$METEOR_M2_3_SAT_MIN_ELEV
fi
if [ "$OBJ_NAME" == "METEOR-M2 4" ]; then
  SAT_MIN_ELEV=$METEOR_M2_4_SAT_MIN_ELEV
fi

# predict the passes within the scheduling window and schedule each one -
# pass_predict.py emits one pass per line:
#   <start_epoch> <end_epoch> <max_elev> <start_azimuth> <azimuth_at_max>
while read -r start_epoch_time end_epoch_time max_elev starting_azimuth azimuth_at_max; do
  file_date_ext=$(date --utc --date="@${start_epoch_time}" +%Y%m%d-%H%M%S)

  # 'at' only schedules on minute boundaries, so extend the capture duration
  # by the seconds the job will start ahead of the actual pass start
  timer=$((end_epoch_time - start_epoch_time + start_epoch_time % 60))

  schedule_enabled_by_sun_elev=1
  sun_min_elev=""
  if [ "$OBJ_NAME" == "METEOR-M2 3" ]; then
    sun_min_elev="${METEOR_M2_3_SCHEDULE_SUN_MIN_ELEV}"
  elif [ "$OBJ_NAME" == "METEOR-M2 4" ]; then
    sun_min_elev="${METEOR_M2_4_SCHEDULE_SUN_MIN_ELEV}"
  fi
  if [ -n "${sun_min_elev}" ]; then
    START_SUN_ELEV=$("$PYTHON" "$SCRIPTS_DIR"/tools/sun.py "$start_epoch_time")
    # a non-numeric reading means sun.py failed - log it rather than letting
    # the comparison below error out and silently schedule the pass anyway
    if ! [[ "$START_SUN_ELEV" =~ ^-?[0-9]+$ ]]; then
      log "Could not determine sun elevation for $OBJ_NAME at START TIME $start_epoch_time (got '$START_SUN_ELEV') - scheduling regardless" "ERROR"
    elif [ "${START_SUN_ELEV}" -lt "${sun_min_elev}" ]; then
      log "Not scheduling $OBJ_NAME with START TIME $start_epoch_time because $START_SUN_ELEV is below configured minimum sun elevation $sun_min_elev" "INFO"
      schedule_enabled_by_sun_elev=0
    fi
  fi

  # schedule capture if elevation is above configured minimum
  if [ "${max_elev}" -gt "${SAT_MIN_ELEV}" ] && [ "${schedule_enabled_by_sun_elev}" -eq "1" ]; then
    direction="null"

    # calculate travel direction
    if [ $starting_azimuth -le 90 ] || [ $starting_azimuth -ge 270 ]; then
      direction="Southbound"
    else
      direction="Northbound"
    fi

    # calculate side of travel
    pass_side="W"
    if [ $azimuth_at_max -ge 0 ] && [ $azimuth_at_max -le 180 ]; then
      pass_side="E"
    fi

    # should at send mail ?
    mail_arg=""
    if [ "${DISABLE_AT_MAIL}" == "true" ]; then
      mail_arg="-M"
    fi

    printf -v safe_obj_name "%q" $(echo "${OBJ_NAME}" | sed "s/ /-/g")
    log "Scheduling capture for: ${safe_obj_name} ${file_date_ext} ${max_elev}" "INFO"
    job_output=$(echo "${NOAA_HOME}/scripts/${RECEIVE_SCRIPT} \"${OBJ_NAME}\" ${safe_obj_name}-${file_date_ext} ${TLE_FILE} \
                                                              ${start_epoch_time} ${timer} ${max_elev} ${direction} ${pass_side}" \
                | at "$(date --date="@${start_epoch_time}" +"%H:%M %D")" ${mail_arg} 2>&1)

    # attempt to capture the job id if job scheduling succeeded
    at_job_id=$(echo $job_output | sed -n 's/.*job \([0-9]\+\) at.*/\1/p')
    if [ -z "${at_job_id}" ]; then
      log "Issue scheduling job: ${job_output}" "WARN"
    else
      log "Scheduled capture with job id: ${at_job_id}" "INFO"

      # update database with scheduled pass
      $SQLITE3 $DB_FILE "INSERT OR REPLACE INTO predict_passes (sat_name,pass_start,pass_end,max_elev,is_active,pass_start_azimuth,azimuth_at_max,direction,at_job_id) VALUES (\"${OBJ_NAME}\",$start_epoch_time,$end_epoch_time,$max_elev,1,$starting_azimuth,$azimuth_at_max,'$direction',$at_job_id);"
    fi
  fi
done < <("$PYTHON" "$SCRIPTS_DIR/tools/pass_predict.py" "$TLE_FILE" "$OBJ_NAME" "$START_TIME_MS" "$END_TIME_MS" "$LAT" "$LON" "$ALT")
