# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

raspberry-noaa-v2 (RN2) is a ground-station framework that captures and decodes NOAA APT and Meteor-M LRPT weather satellite imagery. It targets 64-bit Debian Bookworm (Raspberry Pi 3/4/5 or x64 PCs) and runs entirely on that device — the bash scripts, Ansible playbooks, and PHP webpanel are Linux-only and cannot be run/tested on Windows; development here is editing code that executes on the target machine.

There is no build system, test suite, or linter. The scripts are plain bash/Python, and the webpanel is plain PHP.

## Common commands (run on the target Debian/Pi machine, as a normal user — never root)

```bash
./install_and_upgrade.sh              # one-command install AND config-apply; re-run after any settings.yml change
python3 scripts/tools/validate_yaml.py config/settings.yml config/settings_schema.json   # validate config only
./scripts/schedule.sh -t              # re-schedule passes, downloading fresh TLEs (-x wipes existing future jobs first)
scripts/tools/verification_tool/verification.sh quick   # smoke-test install (nginx, satdump, wxtoimg, meteordemod); 'full' does a complete decode
```

Runtime log for capture events: `/var/log/raspberry-noaa-v2/output.log`.

## Big-picture architecture

**Configuration flow (the key thing to understand):** `config/settings.yml` is the single user-facing config. `install_and_upgrade.sh` validates it against `config/settings_schema.json`, then passes it as `--extra-vars` to Ansible (`ansible/site.yml` = `core.yml` + `webserver.yml`). Ansible renders `~/.noaa-v2.conf` (from `ansible/roles/common/templates/noaa-v2.conf.j2`) — an env-var file that **every bash script sources at startup**, along with `scripts/common.sh` (logging helpers, hardcoded binary paths, satellite frequencies). Adding a new setting therefore touches four places: `settings.yml`, `settings_schema.json`, `noaa-v2.conf.j2`, and the consuming script. Ansible also renders nginx configs, satdump config, udev rules, etc.

**Capture pipeline (bash + `at` + SQLite):**
1. `scripts/schedule.sh` (run by cron nightly and by the installer) downloads TLEs from celestrak into `tmp/`, then per enabled satellite calls `scripts/schedule_captures.sh`.
2. `schedule_captures.sh` uses `predict` to compute upcoming passes, creates one `at` job per pass, and inserts a row into the `predict_passes` table of the SQLite DB `db/panel.db`. Overlapping passes are resolved by `scripts/select_best_overlapping_passes.py`.
3. Each `at` job runs `scripts/receive_noaa.sh` or `scripts/receive_meteor.sh`: records with SatDump live (to ramfs if enough free memory), decodes with wxtoimg or satdump (NOAA) / meteordemod or satdump (Meteor) per the `noaa_decoder`/`meteor_decoder` settings, post-processes via `scripts/image_processors/*` (enhancements, thumbnails, spectrograms, polar plots), inserts into the `decoded_passes` table, and optionally publishes via `scripts/push_processors/*` (Twitter/X, Discord, email, Mastodon, etc.).

**Webpanel (PHP, `webpanel/`):** a tiny hand-rolled MVC framework. `public/index.php` → `Lib/Router.php` maps URLs as `/controller/action?params` to `App/Controllers/{Passes,Captures,Admin}Controller.php`; models in `App/Models` read the same `panel.db`; views are Twig templates in `App/Views` (Twig installed via composer). Translations live in `App/Lang/<two-letter>.php`. The installer copies `webpanel/` to `$WEB_HOME` (served by nginx/php-fpm) and runs `composer install` there — editing files in the repo does nothing until re-deployed.

**Database migrations (`db_migrations/`):** numbered `NN_description.sql` files applied by `update_database.sh`, which guards each with a hand-written idempotency check (grep the schema for the new column). A new migration requires both a new SQL file and a corresponding check block in `update_database.sh`.

**`software/`:** vendored `.deb` packages (satdump, predict, wxtoimg) that Ansible installs per architecture (armhf/arm64/amd64).

## Constraints worth knowing

- Scripts refuse to run as root; the installer and all runtime scripts assume the repo is cloned at `~/raspberry-noaa-v2` under a username ≤ 9 characters (a `predict` limitation).
- `predict` overflows on TLE paths deeper than one subdirectory — TLE files must stay in `tmp/`.
- Satellite frequencies and binary paths are hardcoded in `scripts/common.sh`.
- Only 64-bit Debian Bookworm-based OSes are supported (Bullseye support is sunset).
