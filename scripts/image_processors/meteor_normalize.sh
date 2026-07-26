#!/bin/bash
#
# Purpose: Reduce image size/quality and write file to specified output
#          image file for a METEOR capture.
#
# Input parameters:
#   1. Input .jpg file
#   2. Output .jpg file
#   3. Image quality percent (whole number)
#
# Example:
#   ./meteor_normalize.sh /path/to/inputfile.jpg /path/to/outputfile.jpg 95

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

# input params
INPUT_JPG=$1
OUTPUT_JPG=$2
QUALITY=$3

# generate final normalized image
$CONVERT -interlace Line -quality $QUALITY -colorspace RGB \
         -format jpg "${INPUT_JPG}" "${OUTPUT_JPG}"
