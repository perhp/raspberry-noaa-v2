<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class CapturesController extends \Lib\Controller {
  public function indexAction($args) {
    $capture = $this->loadModel('Capture');

    # gallery filters - only known values are ever used in queries
    $filters = array(
      'sat' => array_key_exists('sat', $args) ? $args['sat'] : '',
      'daynight' => (array_key_exists('daynight', $args) and in_array($args['daynight'], array('day', 'night'))) ? $args['daynight'] : '',
      'min_elev' => (array_key_exists('min_elev', $args) and $args['min_elev'] > 0) ? (int)$args['min_elev'] : 0,
    );

    # query string fragment that carries the active filters through the
    # pagination links
    $filter_qs = '';
    if ($filters['sat'] != '') $filter_qs .= '&sat=' . urlencode($filters['sat']);
    if ($filters['daynight'] != '') $filter_qs .= '&daynight=' . $filters['daynight'];
    if ($filters['min_elev'] > 0) $filter_qs .= '&min_elev=' . $filters['min_elev'];

    $total_pages = $capture->totalPages(Config::CAPTURES_PER_PAGE, $filters);

    # pagination - and check for sanity
    $page_number = 1;
    if (array_key_exists('page_no', $args) and $args['page_no'] > 0) $page_number = $args['page_no'];
    if ($page_number > $total_pages) $page_number = $total_pages;
    if ($page_number < 1) $page_number = 1;

    $capture->getList($page_number, Config::CAPTURES_PER_PAGE, $filters);
    $capture->getSatList();
    $args = array_merge($args, array('capture' => $capture,
                                     'cur_page' => $page_number,
                                     'page_count' => $total_pages,
                                     'filters' => $filters,
                                     'filter_qs' => $filter_qs));

    View::renderTemplate('Captures/index.html', $args);
  }

  public function listImagesAction($args) {
    $capture = $this->loadModel('Capture');
    if (array_key_exists('pass_id', $args) and $args['pass_id'] > 0) $pass_id = $args['pass_id'];

    $capture->getEnhancements($pass_id);
    $capture->getImagePath($pass_id);
    $capture->getGain($pass_id);
    $capture->getSNR($pass_id);
    $capture->getFrameStats($pass_id);

    $args = array_merge($args, array('capture' => $capture));

    View::renderTemplate('Captures/show.html', $args);
  }
}

?>
