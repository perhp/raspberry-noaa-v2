![Raspberry NOAA](../assets/header_1600_v2.png)

In `config/settings.yml`, setting `enable_webhook_push: true` and configuring a `webhook_push_url` will make the station POST a
JSON payload describing every completed capture to that URL. This is a generic integration point for Home Assistant, n8n,
Node-RED, or any custom service - no per-service push processor needed.

## Payload

After each successfully decoded pass, the configured URL receives an HTTP POST with `Content-Type: application/json` and a body
like:

```json
{
  "event": "capture_complete",
  "satellite": "NOAA 18",
  "pass_id": 123,
  "pass_start": 1612831709,
  "pass_end": 1612832628,
  "duration_seconds": 919,
  "max_elevation": 31,
  "pass_direction": "Southbound",
  "pass_side": "E",
  "sun_elevation": 14,
  "gain": 29.7,
  "daylight_pass": true,
  "ground_station": "My Backyard",
  "images": [
    "/srv/images/NOAA-18-20210208-194829-MCIR.jpg",
    "/srv/images/NOAA-18-20210208-194829-MSA.jpg"
  ]
}
```

`pass_start`/`pass_end` are unix epoch timestamps and `images` contains the local paths of all produced enhancements (which map
to `https://<your-webpanel>/images/<basename>` if you want to fetch them remotely).

## Configure Settings and Update

Update your `config/settings.yml` to set `enable_webhook_push: true` and set `webhook_push_url` to your endpoint. If your endpoint
requires authentication, set `webhook_push_auth_token` - it is sent as an `Authorization: Bearer <token>` header. Then, re-run the
installer script `./install_and_upgrade.sh`, which will align your environment.

## Testing (Optional)

You can fire a test event from the command line - the pass metadata fields will simply be empty/zero:

```bash
SAT_NAME="TEST" ./scripts/push_processors/push_webhook.sh 0 1 "/srv/images/some-image.jpg"
```

## Example: Home Assistant

Create a [webhook trigger](https://www.home-assistant.io/docs/automation/trigger/#webhook-trigger) automation with a webhook id,
then point `webhook_push_url` at `https://<your-home-assistant>/api/webhook/<webhook_id>`. The payload fields are available in the
automation as `trigger.json.satellite`, `trigger.json.max_elevation`, etc.
