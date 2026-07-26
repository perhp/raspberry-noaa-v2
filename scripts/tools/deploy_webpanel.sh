#!/bin/bash
#
# Purpose: Deploy webpanel changes from the repo to the live web root ($WEB_HOME)
#          without running the full install_and_upgrade.sh. Replaces the deployed
#          webpanel files (preserving the Ansible-generated Config/ and composer's
#          vendor/) and only runs 'composer install' when dependencies changed.
#
#          Changes to settings.yml, Ansible templates, or nginx config still
#          require ./install_and_upgrade.sh.

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"

if [ -z "$WEB_HOME" ] || [ ! -d "$WEB_HOME" ]; then
  log "Web root '$WEB_HOME' does not exist - run ./install_and_upgrade.sh first" "ERROR"
  exit 1
fi

# decide whether composer needs to run before the copy below overwrites the
# deployed composer.lock we compare against
need_composer=0
if [ ! -d "${WEB_HOME}/vendor" ] || ! cmp -s "${NOAA_HOME}/webpanel/composer.lock" "${WEB_HOME}/composer.lock"; then
  need_composer=1
fi

log "Removing deployed web content (keeping Config/ and vendor/)..." "INFO"
find "$WEB_HOME/" -mindepth 1 -maxdepth 1 ! -name "Config" ! -name "vendor" -exec rm -rf {} + || exit 1

log "Copying webpanel to ${WEB_HOME}..." "INFO"
cp -r "$NOAA_HOME"/webpanel/* "$WEB_HOME"/ || exit 1

log "Setting ownership..." "INFO"
sudo chown -R "$USER":www-data "$WEB_HOME"/ || exit 1

if [ $need_composer -eq 1 ]; then
  log "Dependencies changed - running composer install..." "INFO"
  composer install -d "$WEB_HOME" || exit 1
else
  log "Dependencies unchanged - skipping composer install" "INFO"
fi

log "Webpanel deployed - hard-refresh your browser (Ctrl+F5) to bypass cached assets" "INFO"
