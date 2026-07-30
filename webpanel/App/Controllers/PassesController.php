<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class PassesController extends \Lib\Controller {
  public function indexAction($args) {
    View::renderTemplate('Passes/index.html', $args);
  }

  # JSON endpoint polled by the passes page: live status banner, log tail,
  # and the full pass schedule (rendered client-side)
  public function statusAction($args) {
    $pass = $this->loadModel('Pass');
    $current = $pass->getCurrentCapture();

    # only expose the log tail while a capture is actually running; the
    # fullscreen terminal asks for a longer tail than the inline one
    $log_tail = array();
    if ($current !== null) {
      $lines = isset($_GET['lines']) ? max(1, min(100, (int)$_GET['lines'])) : 12;
      $log_tail = $this->tailLog($lines);
    }

    # date/time labels are formatted here so the browser shows server-local
    # times in the configured format
    $pass->getList();
    $passes = array();
    foreach ($pass->list as $row) {
      $row['date_key'] = date('m/d/y', $row['pass_start']);
      $row['date_label'] = date(Config::PASSES_DATE_FORMAT, $row['pass_start']);
      $row['start_label'] = date('H:i:s', $row['pass_start']);
      $row['end_label'] = date('H:i:s', $row['pass_end']);
      $passes[] = $row;
    }

    header('Content-Type: application/json');
    echo json_encode(array(
      'server_time' => time(),
      'current' => $current,
      'next' => $pass->getNextPass(),
      'passes' => $passes,
      'log_tail' => $log_tail,
    ));
  }

  # return the last $lines lines of the capture log (empty when the log is
  # not configured or not readable by the webserver user)
  private function tailLog($lines) {
    if (!defined('\Config\Config::LOG_FILE')) return array();
    $log_file = Config::LOG_FILE;
    if ($log_file == '' || !is_readable($log_file)) return array();

    $size = filesize($log_file);
    $handle = fopen($log_file, 'r');
    if ($handle === false) return array();

    # read at most the last 16KB - plenty for a handful of lines
    $chunk = 16384;
    fseek($handle, max(0, $size - $chunk));
    $data = stream_get_contents($handle);
    fclose($handle);

    $rows = preg_split('/\r?\n/', trim($data));
    $rows = array_slice($rows, -$lines);

    # SatDump colors its output with ANSI escape codes that end up in the log
    # verbatim, and its live mode reports a meaningless nan/inf progress
    # percentage (no fixed input length) - clean both out of the banner lines
    foreach ($rows as $i => $row) {
      $row = preg_replace('/\x1b\[[0-9;]*[A-Za-z]/', '', $row);
      $row = preg_replace('/Progress (?:nan|inf)%, /', '', $row);
      $rows[$i] = $row;
    }
    return $rows;
  }
}

?>
