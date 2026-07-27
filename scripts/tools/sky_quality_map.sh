#!/bin/bash
#
# Purpose: Regenerate the reception quality sky map from the pass history in
#          panel.db. Run at the end of every capture (and nightly from cron as
#          a fallback); the resulting image is shown on the webpanel Stats page.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

out_file="${IMAGE_OUTPUT}/sky-quality-map.png"
# matplotlib picks the format from the extension, so the temp file has to stay
# a .png - the leading dot keeps it out of the webpanel's image globs
tmp_file="${IMAGE_OUTPUT}/.sky-quality-map.$$.png"

log "Generating reception quality sky map" "INFO"
if "$PYTHON" "$SCRIPTS_DIR/tools/sky_quality_map.py" "$DB_FILE" "$tmp_file" >> $NOAA_LOG 2>&1; then
  # move into place atomically so the webpanel never serves a half-written image
  mv -f "$tmp_file" "$out_file"
else
  log "Failed to generate reception quality sky map - check $NOAA_LOG" "ERROR"
  rm -f "$tmp_file"
fi
