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
                                             predict_passes.azimuth_at_max
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

  # get the enhancements for the particular capture
  public function getEnhancements($id) {
    $query = $this->db_conn->prepare('SELECT daylight_pass,
                                             sat_type,
                                             file_path,
                                             img_count,
                                             has_spectrogram,
                                             has_polar_az_el,
                                             has_polar_direction,
                                             has_pristine,
                                             has_histogram
                                      FROM decoded_passes
                                      WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $pass = $result->fetchArray();

    # build enhancement paths based on satellite type
    switch($pass['sat_type']) {
      case 0: // Meteor
        if ($pass['daylight_pass'] == 1) {
          $enhancements = array_map(function($x) { return "-" . $x . ".jpg"; }, explode(' ', Config::METEOR_DAY_ENHANCEMENTS));
          $additional_enhancements = [
              '-MSA_corrected.jpg',
              '-MSA_projected.jpg',
              '-Natural_Color_corrected.jpg',
              '-Natural_Color_projected.jpg',
              '-Day_Microphysics_corrected.jpg',
              '-Day_Microphysics_projected.jpg',
              '-124_corrected.jpg',
              '-124_projected.jpg',
              '-456_corrected.jpg',
              '-456_projected.jpg',
              '-39um_Shortwave_IR_corrected.jpg',
              '-39um_Shortwave_IR_projected.jpg',
              '-39um_Shortwave_IR_Calibrated_corrected.jpg',
              '-39um_Shortwave_IR_Calibrated_projected.jpg',
              '-MSU-MR-1.jpg',
              '-MSU-MR-2.jpg',
              '-MSU-MR-3.jpg',
              '-MSU-MR-4.jpg',
              '-MSU-MR-5.jpg',
              '-MSU-MR-6.jpg',
              '-321_equirect_projected.jpg',
              '-221_equirect_projected.jpg',
              '-MSA_equirect_projected.jpg',
              '-MCIR_equirect_projected.jpg',
              '-Thermal_Channel_equirect_projected.jpg',
              '-Night_Microphysics_equirect_projected.jpg',
              '-654_equirect_projected.jpg',
              '-MCIR_corrected.jpg',
              '-MCIR_projected.jpg',
              '-321_corrected.jpg',
              '-321_projected.jpg',
              '-221_corrected.jpg',
              '-221_projected.jpg',
              '-654_corrected.jpg',
              '-654_projected.jpg',
              '-Night_Microphysics_corrected.jpg',
              '-Night_Microphysics_projected.jpg',
              '-Thermal_Channel_corrected.jpg',
              '-Thermal_Channel_projected.jpg',
              '-negative224_corrected.jpg',
              '-negative224_projected.jpg',
              '-4_corrected.jpg',
              '-4_projected.jpg',
          ];
        } else {
          $enhancements = array_map(function($x) { return "-" . $x . ".jpg"; }, explode(' ', Config::METEOR_NIGHT_ENHANCEMENTS));
          $additional_enhancements = [
              '-MCIR_corrected.jpg',
              '-MCIR_projected.jpg',
              '-654_corrected.jpg',
              '-654_projected.jpg',
              '-456_corrected.jpg',
              '-456_projected.jpg',
              '-39um_Shortwave_IR_corrected.jpg',
              '-39um_Shortwave_IR_projected.jpg',
              '-39um_Shortwave_IR_Calibrated_corrected.jpg',
              '-39um_Shortwave_IR_Calibrated_projected.jpg',
              '-MSU-MR-1.jpg',
              '-MSU-MR-2.jpg',
              '-MSU-MR-3.jpg',
              '-MSU-MR-4.jpg',
              '-MSU-MR-5.jpg',
              '-MSU-MR-6.jpg',
              '-MCIR_equirect_projected.jpg',
              '-Thermal_Channel_equirect_projected.jpg',
              '-Night_Microphysics_equirect_projected.jpg',
              '-654_equirect_projected.jpg',
              '-Night_Microphysics_corrected.jpg',
              '-Night_Microphysics_projected.jpg',
              '-Thermal_Channel_corrected.jpg',
              '-Thermal_Channel_projected.jpg',
              '-124_corrected.jpg',
              '-124_projected.jpg',
              '-negative224_corrected.jpg',
              '-negative224_projected.jpg',
              '-421_corrected.jpg',
              '-421_projected.jpg',
              '-4_corrected.jpg',
              '-4_projected.jpg',
          ];
        }
        $enhancements = array_merge($enhancements, $additional_enhancements);
        break;
      case 1: // NOAA
        if ($pass['daylight_pass'] == 1) {
          $enhancements = array_map(function($x) { return "-" . $x . ".jpg"; }, explode(' ', Config::NOAA_DAY_ENHANCEMENTS));
        } else {
          $enhancements = array_map(function($x) { return "-" . $x . ".jpg"; }, explode(' ', Config::NOAA_NIGHT_ENHANCEMENTS));
        }
        $satdump_enhancements = [
            "Clouds_Underlay.jpg",
            "-224.jpg",
            "-MSA_Rain.jpg",
            "-MCIR_Rain.jpg",
            "-Thermal_Channel.jpg",
            "-Sea_Surface_Temperature.jpg",
            "-WXtoImg_HVC_N15.jpg",
            "-WXtoImg_HVC_N18.jpg",
            "-WXtoImg_HVC_N19.jpg",
            "-WXtoImg_NO.jpg",
            "-APT-A.jpg",
            "-APT-B.jpg",
            "-APT_channel_A.jpg",
            "-APT_channel_B.jpg",
            "-raw.jpg",
            "-A_individual_equalized.jpg",
            "-B_individual_equalized.jpg",
            "-AVHRR-1.jpg",
            "-AVHRR-4.jpg"
        ];
        $enhancements = array_merge($enhancements, $satdump_enhancements);
        break;
    }

    # remove any enhancements that do not actually exist for this capture
    foreach ($enhancements as $e) {
      $filepath = Config::IMAGE_PATH . '/' . $pass['file_path'] . $e;
      if (!file_exists($filepath)) {
        $key = array_search($e, $enhancements);
        unset($enhancements[$key]);
      }
    }

    # capture spectrogram if one exists
    if ($pass['has_spectrogram'] == '1') {
      array_push($enhancements, '-spectrogram.png');
    }
    # capture polar azimuth elevation graph if one exists
    if ($pass['has_polar_az_el'] == '1') {
      array_push($enhancements, '-polar-azel.jpg');
    }
    # capture polar direction graph if one exists
    if ($pass['has_polar_direction'] == '1') {
      array_push($enhancements, '-polar-direction.png');
    }
    # capture pristine if one exists
    if ($pass['has_pristine'] == '1') {
      array_push($enhancements, '-pristine.png');
    }
    if ($pass['has_histogram'] == '1') {
      array_push($enhancements, '-histogram.jpg');
    }

    $this->enhancements = $enhancements;
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
