#!/bin/bash
#
# Purpose: Prunes (removes) daily timelapse GIFs older than $PRUNE_TIMELAPSES_OLDER_THAN
#          days old. Timelapses are station artifacts with no row in decoded_passes, so
#          the capture prune scripts cannot reach them through the database - they are
#          matched by name and age instead. Both prune_oldest.sh and prune_older_than.sh
#          call this, and it can be cronned on its own if captures are never pruned.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

# a timelapse is a small fraction of the size of the day it summarizes, so it is
# usually worth keeping long after the captures behind it are gone - hence its own
# retention window rather than the captures'. 0 (the default) keeps them forever.
if [ "${PRUNE_TIMELAPSES_OLDER_THAN:-0}" -le 0 ]; then
  exit 0
fi

log "Pruning timelapses older than ${PRUNE_TIMELAPSES_OLDER_THAN} days..." "INFO"
while read -r gif; do
  log "  ${gif} file pruned" "INFO"
done < <(find "${IMAGE_OUTPUT}" -maxdepth 1 -type f -name 'timelapse-*.gif' -mtime "+${PRUNE_TIMELAPSES_OLDER_THAN}" -print -delete)
