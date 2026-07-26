#!/bin/bash
#
# Purpose: Reduce image size/quality and write file to specified output
#          image file for a NOAA capture.
#
# Input parameters:
#   1. Input .jpg file
#   2. Output .jpg file
#   3. Image quality percent (whole number)
#
# Example:
#   ./noaa_normalize.sh /path/to/inputfile.jpg /path/to/outputfile.jpg 95

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

# input params
INPUT_JPG=$1
OUTPUT_JPG=$2
QUALITY=$3

next_in="${INPUT_JPG}"

# generate image with thermal overlay (if specified)
if [ "${ENHANCEMENT}" == "therm" ] && [ "${NOAA_THERMAL_TEMP_OVERLAY}" == "true" ]; then
  log "Overlaying thermal temperature gauge" "INFO"
  $CONVERT -quality 100 -colorspace RGB \
           -format jpg "${next_in}" "${NOAA_HOME}/assets/thermal_gauge.png" \
           -gravity $NOAA_THERMAL_TEMP_OVERLAY_LOCATION \
           -geometry +10+10 \
           -composite "${OUTPUT_JPG}"
  next_in=$OUTPUT_JPG
fi

# generate final normalized image
$CONVERT -interlace Line -quality $QUALITY -colorspace RGB \
         -format jpg "${next_in}" "${OUTPUT_JPG}"
