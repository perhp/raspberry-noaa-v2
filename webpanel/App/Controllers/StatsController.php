<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class StatsController extends \Lib\Controller {
  public function indexAction($args) {
    $sky_map_file = Config::IMAGE_PATH . '/sky-quality-map.png';
    $sky_map_exists = file_exists($sky_map_file);

    $args = array_merge($args, array(
      'sky_map_exists' => $sky_map_exists,
      'sky_map_mtime' => $sky_map_exists ? filemtime($sky_map_file) : 0,
    ));

    View::renderTemplate('Stats/index.html', $args);
  }
}

?>
