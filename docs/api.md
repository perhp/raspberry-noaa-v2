![Raspberry NOAA](../assets/header_1600_v2.png)

The webpanel exposes a small read-only JSON API plus an RSS feed, useful for external dashboards, home automation, and feed
readers. No authentication is required (the endpoints expose the same information as the public webpanel pages).

## Endpoints

| Endpoint | Description |
| --- | --- |
| `GET /api/passes` | all upcoming scheduled passes (name, start/end epochs, elevation, azimuth, direction, status) |
| `GET /api/captures?limit=N` | the latest decoded captures, newest first (default 20, max 100), with `page_url` links |
| `GET /api/capture?id=N` | one capture including the full list of enhancement image URLs |
| `GET /api/status` | the pass currently being captured/processed (if any) and the next scheduled pass |
| `GET /api/rss` | RSS 2.0 feed of the latest 20 captures, with a representative thumbnail as enclosure |

All timestamps are unix epochs (UTC). Example:

```bash
curl http://<your-webpanel>/api/captures?limit=3
```

```json
{
  "server_time": 1785000000,
  "captures": [
    {
      "id": 123,
      "sat_name": "NOAA 18",
      "pass_start": 1784990000,
      "pass_end": 1784990919,
      "max_elev": 42,
      "azimuth_at_max": 96.4,
      "direction": "Southbound",
      "daylight_pass": 1,
      "sat_type": 1,
      "gain": 29.7,
      "max_snr": 14.2,
      "avg_snr": 11.9,
      "page_url": "http://<your-webpanel>/captures/listImages?pass_id=123"
    }
  ]
}
```

## RSS

Point a feed reader at `http://<your-webpanel>/api/rss` to get a feed of new captures as they are decoded. Items link to the
capture page and, when available, carry the same representative thumbnail the gallery uses as an image enclosure.
