<?php

namespace App\Models;

class Stat extends \Lib\Model {
  public $record;
  public $record_axis;
  public $record_mean;
  public $record_days;
  public $per_satellite;
  public $best_snr_overall;
  public $totals;

  # the daily operating record behind the chart recorder: one entry per day of
  # the trailing window, zero-filled, so days the station heard nothing stay in
  # the series instead of collapsing out of it. Decoded captures come from
  # decoded_passes (present for the whole history) and failures from the
  # predict_passes status column (only written since status tracking landed).
  public function getDailyRecord($days) {
    $start_of_today = strtotime('today');
    $cutoff = strtotime('-' . ($days - 1) . ' days', $start_of_today);

    $captures = $this->countByDay("SELECT date(pass_start, 'unixepoch', 'localtime') AS day,
                                          count(*) AS n
                                   FROM decoded_passes
                                   WHERE pass_start >= $cutoff
                                   GROUP BY day;");
    $failures = $this->countByDay("SELECT date(pass_start, 'unixepoch', 'localtime') AS day,
                                          count(*) AS n
                                   FROM predict_passes
                                   WHERE pass_start >= $cutoff AND status = 'failed'
                                   GROUP BY day;");

    $rows = [];
    $peak = 0;
    $decoded_total = 0;
    for ($i = $days - 1; $i >= 0; $i--) {
      $ts = strtotime("-$i days", $start_of_today);
      $day = date('Y-m-d', $ts);
      $decoded = isset($captures[$day]) ? $captures[$day] : 0;
      $failed = isset($failures[$day]) ? $failures[$day] : 0;

      $rows[] = array(
        'day' => $day,
        'timestamp' => $ts,
        'decoded' => $decoded,
        'failed' => $failed,
        'total' => $decoded + $failed,
      );

      $decoded_total += $decoded;
      if ($decoded + $failed > $peak) $peak = $decoded + $failed;
    }

    $this->record = $rows;
    $this->record_axis = $this->niceCeiling($peak);
    $this->record_mean = round($decoded_total / $days, 1);
    $this->record_days = $days;
  }

  # per-satellite aggregates over the whole capture history
  public function getPerSatellite() {
    $query = $this->db_conn->query("SELECT predict_passes.sat_name,
                                           count(*) AS captures,
                                           round(avg(predict_passes.max_elev), 1) AS avg_elev,
                                           round(avg(decoded_passes.max_snr), 1) AS avg_snr,
                                           round(max(decoded_passes.max_snr), 1) AS best_snr,
                                           round(avg(predict_passes.frame_loss_pct), 1) AS avg_frame_loss,
                                           max(decoded_passes.pass_start) AS last_capture
                                    FROM decoded_passes
                                    INNER JOIN predict_passes
                                      ON predict_passes.pass_start = decoded_passes.pass_start
                                    GROUP BY predict_passes.sat_name
                                    ORDER BY captures DESC;");
    $rows = [];
    $best = 0;
    while ($row = $query->fetchArray(SQLITE3_ASSOC)) {
      $rows[] = $row;
      if ($row['best_snr'] !== null && $row['best_snr'] > $best) $best = $row['best_snr'];
    }

    $this->per_satellite = $rows;
    # the avg-SNR bars are scaled against the strongest signal this station has
    # ever recorded - there is no absolute ceiling to normalise against
    $this->best_snr_overall = $best > 0 ? $best : null;
  }

  # station-level totals: lifetime captures plus attempted/failed counts over
  # the trailing 30 days (status tracking only exists for recent passes)
  public function getTotals() {
    $now = time();
    $cutoff = $now - 30 * 86400;
    $total = $this->db_conn->querySingle("SELECT count() FROM decoded_passes;");
    $attempted = $this->db_conn->querySingle("SELECT count() FROM predict_passes
                                              WHERE pass_start > $cutoff AND pass_start < $now
                                                AND status IS NOT NULL;");
    $failed = $this->db_conn->querySingle("SELECT count() FROM predict_passes
                                           WHERE pass_start > $cutoff AND pass_start < $now
                                             AND status = 'failed';");
    $first = $this->db_conn->querySingle("SELECT min(pass_start) FROM decoded_passes;");
    # matches the WHERE clause sky_quality_map.py plots from, so the page can
    # state how many passes the sky map is drawn from
    $plotted = $this->db_conn->querySingle("SELECT count() FROM predict_passes
                                            WHERE pass_start < $now
                                              AND azimuth_at_max IS NOT NULL
                                              AND azimuth_at_max != '';");

    $this->totals = array(
      'total_captures' => $total,
      'attempted_30d' => $attempted,
      'failed_30d' => $failed,
      'success_rate_30d' => $attempted > 0 ? round(100 * ($attempted - $failed) / $attempted) : null,
      'first_capture' => $first,
      'passes_plotted' => $plotted,
    );
  }

  private function countByDay($sql) {
    $query = $this->db_conn->query($sql);
    $counts = [];
    while ($row = $query->fetchArray(SQLITE3_ASSOC)) {
      $counts[$row['day']] = $row['n'];
    }

    return $counts;
  }

  # round the chart's top gridline up to a value that divides in half cleanly,
  # so the midpoint label is a whole number rather than "3.5 passes"
  private function niceCeiling($peak) {
    if ($peak <= 2) return 2;
    if ($peak <= 4) return 4;
    if ($peak <= 10) return $peak + ($peak % 2);

    $step = $peak <= 40 ? 5 : 10;

    return (int) (ceil($peak / $step) * $step);
  }
}

?>
