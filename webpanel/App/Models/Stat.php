<?php

namespace App\Models;

class Stat extends \Lib\Model {
  public $per_day;
  public $max_per_day;
  public $per_satellite;
  public $totals;

  # captures per day over the trailing window, for the activity bar chart
  public function getCapturesPerDay($days) {
    $cutoff = time() - $days * 86400;
    $query = $this->db_conn->query("SELECT date(pass_start, 'unixepoch', 'localtime') AS day,
                                           count(*) AS captures
                                    FROM decoded_passes
                                    WHERE pass_start > $cutoff
                                    GROUP BY day
                                    ORDER BY day ASC;");
    $rows = [];
    $max = 0;
    while ($row = $query->fetchArray(SQLITE3_ASSOC)) {
      $rows[] = $row;
      if ($row['captures'] > $max) $max = $row['captures'];
    }

    $this->per_day = $rows;
    $this->max_per_day = $max;
  }

  # per-satellite aggregates over the whole capture history
  public function getPerSatellite() {
    $query = $this->db_conn->query("SELECT predict_passes.sat_name,
                                           count(*) AS captures,
                                           round(avg(predict_passes.max_elev), 1) AS avg_elev,
                                           round(avg(decoded_passes.max_snr), 1) AS avg_snr,
                                           round(max(decoded_passes.max_snr), 1) AS best_snr,
                                           max(decoded_passes.pass_start) AS last_capture
                                    FROM decoded_passes
                                    INNER JOIN predict_passes
                                      ON predict_passes.pass_start = decoded_passes.pass_start
                                    GROUP BY predict_passes.sat_name
                                    ORDER BY captures DESC;");
    $rows = [];
    while ($row = $query->fetchArray(SQLITE3_ASSOC)) {
      $rows[] = $row;
    }

    $this->per_satellite = $rows;
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

    $this->totals = array(
      'total_captures' => $total,
      'attempted_30d' => $attempted,
      'failed_30d' => $failed,
      'success_rate_30d' => $attempted > 0 ? round(100 * ($attempted - $failed) / $attempted) : null,
    );
  }
}

?>
