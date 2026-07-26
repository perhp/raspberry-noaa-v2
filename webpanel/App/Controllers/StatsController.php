<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class StatsController extends \Lib\Controller {
  public function indexAction($args) {
    $stat = $this->loadModel('Stat');
    $stat->getCapturesPerDay(30);
    $stat->getPerSatellite();
    $stat->getTotals();

    $sky_map_file = Config::IMAGE_PATH . '/sky-quality-map.png';
    $sky_map_exists = file_exists($sky_map_file);

    # newest daily timelapse GIF, if the feature is producing them - the
    # date-stamped filenames sort chronologically
    $timelapse_file = '';
    $timelapses = glob(Config::IMAGE_PATH . '/timelapse-*.gif');
    if ($timelapses !== false && count($timelapses) > 0) {
      sort($timelapses);
      $timelapse_file = basename(end($timelapses));
    }

    $args = array_merge($args, array(
      'stat' => $stat,
      'sky_map_exists' => $sky_map_exists,
      'sky_map_mtime' => $sky_map_exists ? filemtime($sky_map_file) : 0,
      'timelapse_file' => $timelapse_file,
    ));

    View::renderTemplate('Stats/index.html', $args);
  }
}

?>
