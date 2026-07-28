<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class StatsController extends \Lib\Controller {
  public function indexAction($args) {
    $stat = $this->loadModel('Stat');
    $stat->getDailyRecord(30);
    $stat->getPerSatellite();
    $stat->getTotals();

    $sky_map_file = Config::IMAGE_PATH . '/sky-quality-map.png';
    $sky_map_exists = file_exists($sky_map_file);

    $args = array_merge($args, array(
      'stat' => $stat,
      'sky_map_exists' => $sky_map_exists,
      'sky_map_mtime' => $sky_map_exists ? filemtime($sky_map_file) : 0,
      'timelapse_files' => $this->newestPerVariant('/timelapse-*.gif', '/^timelapse-(\d{8})(?:-(.+))?\.gif$/'),
      'mosaic_files' => $this->newestPerVariant('/mosaic-*.jpg', '/^mosaic-(\d{8})-(.+)\.jpg$/'),
    ));

    View::renderTemplate('Stats/index.html', $args);
  }

  # map of projection variant => newest matching file, for the daily artifacts
  # the best of day job builds. Both are named <kind>-YYYYMMDD-<variant>.<ext>,
  # so the date-stamped names sort chronologically and the last one seen for a
  # variant is its most recent. Timelapses produced before the per-projection
  # naming carry no variant and are keyed by an empty string. The capture date
  # is lifted out of the name so the page can caption a plate with the day it
  # covers rather than its filename.
  private function newestPerVariant($glob_pattern, $name_pattern) {
    $newest = array();
    $files = glob(Config::IMAGE_PATH . $glob_pattern);
    if ($files === false) {
      return $newest;
    }

    sort($files);
    foreach ($files as $file) {
      if (preg_match($name_pattern, basename($file), $matches)) {
        $variant = isset($matches[2]) ? $matches[2] : '';
        $newest[$variant] = array(
          'file' => basename($file),
          'date' => strtotime($matches[1]),
        );
      }
    }
    ksort($newest);

    return $newest;
  }
}

?>
