# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

raspberry-noaa-v2 (RN2) is a ground-station framework that captures and decodes NOAA APT and Meteor-M LRPT weather satellite imagery. It targets 64-bit Debian Trixie only (Raspberry Pi 3/4/5 or x64 PCs; `core.yml` asserts this at install time) and runs entirely on that device — the bash scripts, Ansible playbooks, and PHP webpanel are Linux-only and cannot be run/tested on Windows; development here is editing code that executes on the target machine. SatDump is the sole decoder for both NOAA and Meteor.

There is no build system, test suite, or linter. The scripts are plain bash/Python, and the webpanel is plain PHP.

## Common commands (run on the target Debian/Pi machine, as a normal user — never root)

```bash
./install_and_upgrade.sh              # one-command install AND config-apply; re-run after any settings.yml change
python3 scripts/tools/validate_yaml.py config/settings.yml config/settings_schema.json   # validate config only
./scripts/schedule.sh -t              # re-schedule passes, downloading fresh TLEs (-x wipes existing future jobs first)
scripts/tools/verification_tool/verification.sh   # smoke-test install (permissions, packages, nginx and satdump dry runs)
```

Runtime log for capture events: `/var/log/raspberry-noaa-v2/output.log`.

## Big-picture architecture

**Configuration flow (the key thing to understand):** `config/settings.yml` is the single user-facing config. It is gitignored — the tracked template is `config/settings.yml.example`, which the installer copies on first run (then exits so the user can edit it). `install_and_upgrade.sh` validates settings.yml against `config/settings_schema.json`, then passes it as `--extra-vars` to Ansible (`ansible/site.yml` = `core.yml` + `webserver.yml`). Ansible renders `~/.noaa-v2.conf` (from `ansible/roles/common/templates/noaa-v2.conf.j2`) — an env-var file that **every bash script sources at startup**, along with `scripts/common.sh` (logging helpers, hardcoded binary paths, satellite frequencies). Adding a new setting therefore touches four places: `settings.yml`, `settings_schema.json`, `noaa-v2.conf.j2`, and the consuming script. Ansible also renders nginx configs, satdump config, udev rules, etc.

**Capture pipeline (bash + `at` + SQLite):**
1. `scripts/schedule.sh` (run by cron nightly and by the installer) downloads TLEs from celestrak into `tmp/`, then per enabled satellite calls `scripts/schedule_captures.sh`.
2. `schedule_captures.sh` computes upcoming passes with `scripts/tools/pass_predict.py` (Python/ephem, one pass per output line), creates one `at` job per pass, and inserts a row into the `predict_passes` table of the SQLite DB `db/panel.db`. Overlapping passes are resolved by `scripts/select_best_overlapping_passes.py`.
3. Each `at` job runs `scripts/receive_noaa.sh` or `scripts/receive_meteor.sh`: records and decodes with SatDump live (`--finish_processing`; audio/CADU to ramfs if enough free memory), post-processes via `scripts/image_processors/*` (normalization, thumbnails, polar plots), inserts into the `decoded_passes` table, and optionally publishes via `scripts/push_processors/*` (Twitter/X, Discord, email, Mastodon, etc.).

**Python runtime:** Ansible creates a virtualenv at `~/.rn2_venv` (`--system-site-packages`, so apt-installed numpy/matplotlib/ephem are visible) holding the pip-only packages (envbash always; push-processor libs like tweepy/facebook-sdk only when the matching push option is enabled — see `social_media.yml`). `~/.noaa-v2.conf` exports `PYTHON` pointing at it; all runtime scripts invoke Python via `"$PYTHON"` (with a system-python fallback in `common.sh`).

**Webpanel (PHP, `webpanel/`):** a tiny hand-rolled MVC framework. `public/index.php` → `Lib/Router.php` maps URLs as `/controller/action?params` to `App/Controllers/{Passes,Captures,Admin}Controller.php`; models in `App/Models` read the same `panel.db`; views are Twig templates in `App/Views` (Twig installed via composer). Translations live in `App/Lang/<two-letter>.php`. The installer copies `webpanel/` to `$WEB_HOME` (served by nginx/php-fpm) and runs `composer install` there — editing files in the repo does nothing until re-deployed.

**Database migrations (`db_migrations/`):** numbered `NN_description.sql` files applied by `update_database.sh`, which guards each with a hand-written idempotency check (grep the schema for the new column). A new migration requires both a new SQL file and a corresponding check block in `update_database.sh`.

**`software/`:** only the sdrplay API installer remains; SatDump is always built from source by Ansible (skipped when `/usr/bin/satdump` already exists).

## Constraints worth knowing

- Scripts refuse to run as root; the installer and all runtime scripts assume the repo is cloned at `~/raspberry-noaa-v2`.
- Satellite frequencies and binary paths are hardcoded in `scripts/common.sh`.
- Pass prediction is done by `scripts/tools/pass_predict.py` using python3-ephem (the legacy `predict` binary and its username/TLE-path constraints are gone). The wxtoimg and MeteorDemod decoders were removed along with their settings, image processors, and dependencies — SatDump does all decoding.
- Ansible has no OS version gating anymore: `core.yml` fails fast on anything that isn't Trixie (native PHP 8.4, ntpsec, source-built SatDump). The osmocom rtl-sdr source build remains — it provides RTL-SDR V4 support.
