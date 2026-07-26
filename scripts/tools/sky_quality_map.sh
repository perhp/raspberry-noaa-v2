#!/bin/bash
#
# Purpose: Regenerate the reception quality sky map from the pass history in
#          panel.db. Run nightly from cron; the resulting image is shown on
#          the webpanel Stats page.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

log "Generating reception quality sky map" "INFO"
"$PYTHON" "$SCRIPTS_DIR/tools/sky_quality_map.py" "$DB_FILE" "${IMAGE_OUTPUT}/sky-quality-map.png" >> $NOAA_LOG 2>&1
