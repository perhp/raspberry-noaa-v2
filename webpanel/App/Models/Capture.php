<?php

namespace App\Models;
use Config\Config;

class Capture extends \Lib\Model {
  public $enhancements;
  public $image_path;
  public $start_epoch;
  public $travel_direction;
  public $gain;
  public $max_snr;
  public $avg_snr;
  public $frames_received;
  public $frames_expected;
  public $frame_loss_pct;
  public $largest_frame_gap;
  public $sat_list;

  # build the WHERE clause for the gallery filters (satellite, day/night,
  # minimum elevation) - values are bound as named parameters by bindFilters
  private function filterClause($filters) {
    $clauses = [];
    if (!empty($filters['sat'])) {
      $clauses[] = 'predict_passes.sat_name = :sat';
    }
    if (isset($filters['daynight']) && $filters['daynight'] === 'day') {
      $clauses[] = 'decoded_passes.daylight_pass = 1';
    } elseif (isset($filters['daynight']) && $filters['daynight'] === 'night') {
      $clauses[] = 'decoded_passes.daylight_pass = 0';
    }
    if (!empty($filters['min_elev'])) {
      $clauses[] = 'predict_passes.max_elev >= :min_elev';
    }
    return count($clauses) > 0 ? ' WHERE ' . implode(' AND ', $clauses) : '';
  }

  private function bindFilters($query, $filters) {
    if (!empty($filters['sat'])) {
      $query->bindValue(':sat', $filters['sat']);
    }
    if (!empty($filters['min_elev'])) {
      $query->bindValue(':min_elev', (int)$filters['min_elev']);
    }
  }

  # get a list of captures for the given page and total number
  # of configured images per page, restricted by the optional gallery filters
  public function getList($page, $img_per_page, $filters = []) {
    $query = $this->db_conn->prepare("SELECT decoded_passes.id,
                                             predict_passes.pass_start,
                                             file_path,
                                             daylight_pass,
                                             sat_type,
                                             gain,
                                             max_snr,
                                             avg_snr,
                                             predict_passes.sat_name,
                                             predict_passes.max_elev,
                                             predict_passes.pass_start_azimuth,
                                             predict_passes.direction,
                                             predict_passes.azimuth_at_max,
                                             predict_passes.frames_received,
                                             predict_passes.frames_expected,
                                             predict_passes.frame_loss_pct,
                                             predict_passes.largest_frame_gap
                                             FROM decoded_passes
                                             INNER JOIN predict_passes
                                               ON predict_passes.pass_start = decoded_passes.pass_start"
                                             . $this->filterClause($filters) .
                                             " ORDER BY decoded_passes.pass_start DESC LIMIT :limit OFFSET :offset;");
    $this->bindFilters($query, $filters);
    $query->bindValue(':limit', $img_per_page);
    $query->bindValue(':offset', $img_per_page * ($page-1));
    $result = $query->execute();

    $captures = [];
    $i = 0;
    while ($row = $result->fetchArray()) {
      $captures[$i] = $row;
      $i++;
    }

    $this->list = $captures;
  }

  # get total number of pages to display images given the
  # passed number of images per page and the optional gallery filters
  public function totalPages($images_per_page, $filters = []) {
    $query = $this->db_conn->prepare("SELECT count() FROM decoded_passes
                                      INNER JOIN predict_passes
                                        ON predict_passes.pass_start = decoded_passes.pass_start"
                                      . $this->filterClause($filters) . ";");
    $this->bindFilters($query, $filters);
    $result = $query->execute();
    $row = $result->fetchArray();
    return ceil($row[0]/$images_per_page);
  }

  # get the most recent decoded capture with its reception metrics, for the
  # live status terminal's idle summary line
  public function getLatest() {
    $query = $this->db_conn->query("SELECT decoded_passes.id,
                                           decoded_passes.pass_start,
                                           decoded_passes.gain,
                                           decoded_passes.max_snr,
                                           decoded_passes.avg_snr,
                                           predict_passes.sat_name,
                                           predict_passes.max_elev,
                                           predict_passes.frame_loss_pct
                                    FROM decoded_passes
                                    INNER JOIN predict_passes
                                      ON predict_passes.pass_start = decoded_passes.pass_start
                                    ORDER BY decoded_passes.pass_start DESC LIMIT 1;");
    $row = $query->fetchArray(SQLITE3_ASSOC);
    return $row === false ? null : $row;
  }

  # get the distinct satellite names present in the capture history, for
  # the gallery filter dropdown
  public function getSatList() {
    $query = $this->db_conn->query("SELECT DISTINCT predict_passes.sat_name
                                    FROM decoded_passes
                                    INNER JOIN predict_passes
                                      ON predict_passes.pass_start = decoded_passes.pass_start
                                    ORDER BY predict_passes.sat_name;");
    $sats = [];
    while ($row = $query->fetchArray()) {
      $sats[] = $row['sat_name'];
    }
    $this->sat_list = $sats;
  }

  # suffixes that are not satellite imagery - these are appended after the
  # imagery so the graphs and diagnostics sort to the end of the gallery
  const AUXILIARY_ENHANCEMENTS = [
      '-spectrogram.png',
      '-polar-azel.jpg',
      '-polar-direction.png',
      '-pristine.png',
      '-histogram.jpg',
  ];

  # suffixes that exist only to be served elsewhere and must never show up as
  # an enhancement in the gallery
  const EXCLUDED_ENHANCEMENTS = [
      '-website-thumbnail.jpg',
  ];

  # get the enhancements for the particular capture
  #
  # The products SatDump emits vary by satellite, decoder version, signal
  # quality and illumination, so this enumerates what is actually on disk
  # instead of intersecting with a hardcoded day/night list - under the old
  # approach any product missing from the list (for example the 221, 321 and
  # MSA composites on a night pass) was silently dropped from the gallery.
  public function getEnhancements($id) {
    $query = $this->db_conn->prepare('SELECT file_path
                                      FROM decoded_passes
                                      WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $pass = $result->fetchArray();
    if ($pass === false) {
      $this->enhancements = [];
      return;
    }

    # glob() treats *, ? and [] as wildcards, so escape them - capture
    # filenames are generated as <sat>-<date>-<time> and never contain them,
    # but a stray character must not widen the match to other captures
    $prefix = Config::IMAGE_PATH . '/' . $pass['file_path'];
    $pattern = preg_replace('/([*?\[\]])/', '[$1]', $prefix) . '-*';

    $imagery = [];
    $auxiliary = [];
    foreach (glob($pattern) as $file) {
      $suffix = substr($file, strlen($prefix));
      if (in_array($suffix, self::EXCLUDED_ENHANCEMENTS)) {
        continue;
      }
      if (!in_array(strtolower(pathinfo($file, PATHINFO_EXTENSION)), ['jpg', 'jpeg', 'png', 'gif'])) {
        continue;
      }
      if (in_array($suffix, self::AUXILIARY_ENHANCEMENTS)) {
        $auxiliary[] = $suffix;
      } else {
        $imagery[] = $suffix;
      }
    }

    sort($imagery);
    # keep the auxiliary graphs in the order declared above rather than
    # alphabetically, so the gallery tail is stable across captures
    $auxiliary = array_values(array_intersect(self::AUXILIARY_ENHANCEMENTS, $auxiliary));

    $this->enhancements = array_merge($imagery, $auxiliary);
  }

  # get the image path for the specific capture
  public function getImagePath($id) {
    $query = $this->db_conn->prepare('SELECT file_path FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $image = $result->fetchArray();

    $this->image_path = $image['file_path'];
  }

  # get the gain for the specific capture
  public function getGain($id) {
    $query = $this->db_conn->prepare('SELECT gain FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $image = $result->fetchArray();

    $this->gain = $image['gain'];
  }

  # get the SNR quality metrics for the specific capture (null for captures
  # that predate the metrics or produced no demodulator readings)
  public function getSNR($id) {
    $query = $this->db_conn->prepare('SELECT max_snr, avg_snr FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $row = $result->fetchArray();

    $this->max_snr = $row['max_snr'];
    $this->avg_snr = $row['avg_snr'];
  }

  # get the CADU frame reception metrics for the specific capture (null for
  # NOAA APT captures, which have no frames, and for captures that predate
  # the metrics) - these live on predict_passes so that failed captures,
  # which never get a decoded_passes row, carry them too
  public function getFrameStats($id) {
    $query = $this->db_conn->prepare('SELECT predict_passes.frames_received,
                                             predict_passes.frames_expected,
                                             predict_passes.frame_loss_pct,
                                             predict_passes.largest_frame_gap
                                      FROM decoded_passes
                                      INNER JOIN predict_passes
                                        ON predict_passes.pass_start = decoded_passes.pass_start
                                      WHERE decoded_passes.id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $row = $result->fetchArray();

    $this->frames_received = $row === false ? null : $row['frames_received'];
    $this->frames_expected = $row === false ? null : $row['frames_expected'];
    $this->frame_loss_pct = $row === false ? null : $row['frame_loss_pct'];
    $this->largest_frame_gap = $row === false ? null : $row['largest_frame_gap'];
  }

  # get the epoch start time for the capture
  public function getStartEpoch($id) {
    $query = $this->db_conn->prepare('SELECT pass_start FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $res = $result->fetchArray();

    $this->start_epoch = $res['pass_start'];
  }

  # delete a capture by id
  public function deleteById($id) {
    $query = $this->db_conn->prepare('DELETE FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
  }
}

?>
