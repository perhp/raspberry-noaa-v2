![Raspberry NOAA](../assets/header_1600_v2.png)

The station health watchdog is an hourly cron job (`scripts/tools/health_watchdog.sh`, installed automatically by the installer)
that catches the failure modes an unattended ground station otherwise suffers silently:

| Check | Alert condition |
| --- | --- |
| Recent captures | no successfully decoded capture in `watchdog_max_hours_without_capture` hours (default 48) |
| Failing passes | 3+ passes attempted in the last 24 hours and every one of them failed |
| Disk usage | image storage filesystem at or above `watchdog_disk_usage_threshold` percent (default 90) |
| Scheduling | the `at` queue is completely empty (TLE download or `schedule.sh` broken) |
| SDR presence | `receiver_type: rtlsdr` only - no RTL device visible on USB |

Alerts are always written to the log (`/var/log/raspberry-noaa-v2/output.log`) and are additionally sent through every enabled
text-capable push channel: Telegram, Discord, Pushover, Slack, and the generic webhook (as an `event: "station_alert"` JSON
payload). Each distinct alert is re-sent at most once every 24 hours while the condition persists, and the suppression state
resets as soon as the check passes again.

## Configuration

Watchdog settings in `config/settings.yml`:

```yaml
enable_health_watchdog: true
watchdog_max_hours_without_capture: 48
watchdog_disk_usage_threshold: 90
```

Set `enable_health_watchdog: false` to disable the checks entirely (the cron entry remains but exits immediately). After changing
settings, re-run `./install_and_upgrade.sh`.

Note: if you only schedule satellites sporadically (or have disabled all satellites), the "recent captures" and "scheduling"
checks will naturally fire - either raise `watchdog_max_hours_without_capture` or disable the watchdog in that case.

## Testing

Run it by hand to see the check results in the log:

```bash
./scripts/tools/health_watchdog.sh
tail -20 /var/log/raspberry-noaa-v2/output.log
```

To force a test alert, temporarily set `watchdog_disk_usage_threshold: 1`, re-run the installer, and execute the script manually
(remember to revert afterwards). Alert suppression state lives in `~/.rn2_watchdog_state` - delete the file to reset it.
