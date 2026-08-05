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

    # timelapses accumulate a file per projection per day, so the page leads with
    # the latest of each and keeps the back catalogue behind a disclosure button
    $timelapses = $this->byVariant('/timelapse-*.gif', '/^timelapse-(\d{8})(?:-(.+))?\.gif$/');

    $args = array_merge($args, array(
      'stat' => $stat,
      'sky_map_exists' => $sky_map_exists,
      'sky_map_mtime' => $sky_map_exists ? filemtime($sky_map_file) : 0,
      'timelapse_files' => $timelapses['newest'],
      'older_timelapse_files' => $timelapses['older'],
      'mosaic_files' => $this->newestPerVariant('/mosaic-*.jpg', '/^mosaic-(\d{8})-(.+)\.jpg$/'),
    ));

    View::renderTemplate('Stats/index.html', $args);
  }

  # map of projection variant => newest matching file, for the daily artifacts
  # the best of day job builds. See byVariant() for how the set is read.
  private function newestPerVariant($glob_pattern, $name_pattern) {
    $split = $this->byVariant($glob_pattern, $name_pattern);

    return $split['newest'];
  }

  # reads a set of daily artifacts into 'newest' (map of projection variant =>
  # its most recent file) and 'older' (everything those displaced, most recent
  # day first). Both kinds are named <kind>-YYYYMMDD-<variant>.<ext>, so the
  # date-stamped names sort chronologically and the last one seen for a variant
  # is its most recent. Timelapses produced before the per-projection naming
  # carry no variant and are keyed by an empty string. The capture date is
  # lifted out of the name so the page can caption a plate with the day it
  # covers rather than its filename.
  private function byVariant($glob_pattern, $name_pattern) {
    $newest = array();
    $older = array();
    $files = glob(Config::IMAGE_PATH . $glob_pattern);
    if ($files === false) {
      return array('newest' => $newest, 'older' => $older);
    }

    sort($files);
    foreach ($files as $file) {
      if (!preg_match($name_pattern, basename($file), $matches)) {
        continue;
      }
      $variant = isset($matches[2]) ? $matches[2] : '';
      if (isset($newest[$variant])) {
        # displaced by a later day - it belongs to the back catalogue now
        $older[] = $newest[$variant];
      }
      $newest[$variant] = array(
        'file' => basename($file),
        'date' => strtotime($matches[1]),
        'variant' => $variant,
      );
    }
    ksort($newest);

    # the leftovers arrive oldest first and interleaved across variants; the
    # back catalogue reads newest day first, variants together within a day
    usort($older, function ($a, $b) {
      if ($a['date'] !== $b['date']) {
        return $b['date'] - $a['date'];
      }

      return strcmp($a['variant'], $b['variant']);
    });

    return array('newest' => $newest, 'older' => $older);
  }
}

?>
