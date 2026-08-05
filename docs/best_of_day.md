![Raspberry NOAA](../assets/header_1600_v2.png)

The daily summary push (`scripts/tools/best_of_day.sh`, run by cron every evening at 22:30) picks the best capture of the day and
pushes a single post through the enabled push channels (Telegram, Discord, Pushover, Slack, Matrix, Mastodon, Bluesky, Twitter,
Facebook, email). It is a lower-noise alternative - or complement - to per-pass pushing: disable the per-pass channels you find
too chatty, or combine this with the push quality gate.

"Best" is ranked by peak SNR (from the per-pass quality metrics), falling back to maximum pass elevation for captures without
SNR readings. The post uses a representative composite image (MSA/MCIR for NOAA, the corrected Meteor composites) from the winning
capture.

## Daily timelapse

With `enable_daily_timelapse: true`, the script additionally assembles an animated GIF from the day's equirectangular Meteor
projections (which are geographically aligned, so consecutive passes animate cleanly) and attaches it to the daily post. This
requires `meteor_create_equidistant_projection: true` and at least two matching passes on the day. The projection to animate is
selected with `daily_timelapse_suffix` (e.g. `-321_equirect_projected.jpg` for daytime visible, `-MCIR_equirect_projected.jpg`
for an all-hours option).

The most recent timelapse per projection is shown on the webpanel **Stats** page, with every earlier day behind a **Show
older** button in the same section (the GIFs live at `/srv/images/timelapse-YYYYMMDD-<projection>.gif`, so any of them can
also be opened directly as `/images/timelapse-YYYYMMDD-<projection>.gif`). Old timelapses are cleaned up by
`scripts/prune_scripts/prune_timelapses.sh` under their own retention window, the `delete_timelapses_older_than_n`
setting - the two capture prune scripts both call it - see [pruning](pruning.md).

## Configuration

```yaml
enable_best_of_day_push: true
enable_daily_timelapse: false
daily_timelapse_suffix: "-321_equirect_projected.jpg"
```

Re-run `./install_and_upgrade.sh` after changing settings. To test without waiting for the cron run:

```bash
./scripts/tools/best_of_day.sh
tail -20 /var/log/raspberry-noaa-v2/output.log
```
