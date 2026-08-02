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

    # only expose the log tail while a capture is actually running
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

    # most recent decoded capture, for the idle summary line
    $capture = $this->loadModel('Capture');
    $latest = $capture->getLatest();
    if ($latest !== null) {
      $latest['time_label'] = date('H:i', $latest['pass_start']);
    }

    header('Content-Type: application/json');
    echo json_encode(array(
      'server_time' => time(),
      # matches the passes' date_key so the client can count today's rows
      'today' => date('m/d/y'),
      'current' => $current,
      'next' => $pass->getNextPass(),
      'passes' => $passes,
      'log_tail' => $log_tail,
      'latest' => $latest,
      'vitals' => $this->vitals(),
      'tle_age' => $this->tleAge(),
    ));
  }

  # age in seconds of the TLE set used for pass prediction, or null when the
  # file is missing or the deployed Config predates the TLE_FILE constant
  private function tleAge() {
    if (!defined('\Config\Config::TLE_FILE')) return null;
    $tle_file = Config::TLE_FILE;
    if ($tle_file == '' || !is_readable($tle_file)) return null;
    $mtime = @filemtime($tle_file);
    return $mtime === false ? null : max(0, time() - $mtime);
  }

  # host vitals for the idle dashboard - every reading is optional, so a
  # missing /sys or /proc entry just drops that field from the response
  private function vitals() {
    $vitals = array();

    $temp = @file_get_contents('/sys/class/thermal/thermal_zone0/temp');
    if ($temp !== false && trim($temp) !== '') {
      $vitals['cpu_temp'] = round((int)trim($temp) / 1000, 1);
    }

    if (function_exists('sys_getloadavg')) {
      $load = sys_getloadavg();
      if ($load !== false) {
        $vitals['load'] = round($load[0], 2);
      }
    }

    $meminfo = @file_get_contents('/proc/meminfo');
    if ($meminfo !== false &&
        preg_match('/^MemTotal:\s+(\d+)/m', $meminfo, $total) &&
        preg_match('/^MemAvailable:\s+(\d+)/m', $meminfo, $avail) &&
        (int)$total[1] > 0) {
      $vitals['mem_used_pct'] = (int)round(100 * (1 - $avail[1] / $total[1]));
    }

    $uptime = @file_get_contents('/proc/uptime');
    if ($uptime !== false) {
      $vitals['uptime'] = (int)floatval($uptime);
    }

    # free space where captures land - the disk that actually fills up
    if (defined('\Config\Config::IMAGE_PATH')) {
      $free = @disk_free_space(Config::IMAGE_PATH);
      if ($free !== false) {
        $vitals['disk_free'] = $free;
      }
    }

    return $vitals;
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

    # read at most the last 64KB - enough headroom for a 100-line tail even
    # with SatDump's long ANSI-decorated lines
    $chunk = 65536;
    fseek($handle, max(0, $size - $chunk));
    $data = stream_get_contents($handle);
    fclose($handle);

    # SatDump redraws its live progress line with bare carriage returns, so a
    # capture can write huge \r-separated runs with barely any real newlines -
    # treat \r as a line break too, or the tail collapses into a few giant rows
    $rows = preg_split('/\r\n|\r|\n/', $data);

    # SatDump colors its output with ANSI escape codes that end up in the log
    # verbatim, and its live mode reports a meaningless nan/inf progress
    # percentage (no fixed input length) - clean both out, then drop rows that
    # are empty after cleanup so they don't eat into the requested line count
    $out = array();
    foreach ($rows as $row) {
      $row = preg_replace('/\x1b\[[0-9;]*[A-Za-z]/', '', $row);
      $row = preg_replace('/Progress (?:nan|inf)%, /', '', $row);
      if (trim($row) === '') continue;
      $out[] = $row;
    }
    return array_slice($out, -$lines);
  }
}

?>
