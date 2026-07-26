<?php

namespace App\Controllers;

use Config\Config;

# read-only JSON API plus an RSS feed of the latest captures, for external
# dashboards, home automation, and feed readers:
#   /api/passes        - upcoming scheduled passes
#   /api/captures      - latest decoded captures (?limit=N, max 100)
#   /api/capture?id=N  - one capture including its enhancement image URLs
#   /api/status        - current/next pass, same data as the live banner
#   /api/rss           - RSS 2.0 feed of the latest captures
class ApiController extends \Lib\Controller {

  private function json($data) {
    header('Content-Type: application/json');
    echo json_encode($data);
  }

  private function baseUrl() {
    $scheme = isset($_SERVER['REQUEST_SCHEME']) ? $_SERVER['REQUEST_SCHEME'] : 'http';
    return $scheme . '://' . $_SERVER['HTTP_HOST'];
  }

  public function passesAction($args) {
    $now = time();
    $query = $this->db_conn->query("SELECT sat_name,
                                           pass_start,
                                           pass_end,
                                           max_elev,
                                           pass_start_azimuth,
                                           azimuth_at_max,
                                           direction,
                                           is_active,
                                           status
                                    FROM predict_passes
                                    WHERE pass_end > $now
                                    ORDER BY pass_start ASC;");
    $passes = [];
    while ($row = $query->fetchArray(SQLITE3_ASSOC)) {
      $passes[] = $row;
    }

    $this->json(array('server_time' => $now, 'passes' => $passes));
  }

  public function capturesAction($args) {
    $limit = 20;
    if (array_key_exists('limit', $args) and (int)$args['limit'] > 0) $limit = (int)$args['limit'];
    if ($limit > 100) $limit = 100;

    $query = $this->db_conn->prepare("SELECT decoded_passes.id,
                                             predict_passes.sat_name,
                                             decoded_passes.pass_start,
                                             predict_passes.pass_end,
                                             predict_passes.max_elev,
                                             predict_passes.azimuth_at_max,
                                             predict_passes.direction,
                                             decoded_passes.daylight_pass,
                                             decoded_passes.sat_type,
                                             decoded_passes.gain,
                                             decoded_passes.max_snr,
                                             decoded_passes.avg_snr
                                      FROM decoded_passes
                                      INNER JOIN predict_passes
                                        ON predict_passes.pass_start = decoded_passes.pass_start
                                      ORDER BY decoded_passes.pass_start DESC LIMIT ?;");
    $query->bindValue(1, $limit);
    $result = $query->execute();

    $base_url = $this->baseUrl();
    $captures = [];
    while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
      $row['page_url'] = $base_url . '/captures/listImages?pass_id=' . $row['id'];
      $captures[] = $row;
    }

    $this->json(array('server_time' => time(), 'captures' => $captures));
  }

  public function captureAction($args) {
    if (!array_key_exists('id', $args) or (int)$args['id'] <= 0) {
      http_response_code(400);
      $this->json(array('error' => "missing or invalid 'id' parameter"));
      return;
    }
    $id = (int)$args['id'];

    $query = $this->db_conn->prepare("SELECT decoded_passes.id,
                                             predict_passes.sat_name,
                                             decoded_passes.pass_start,
                                             predict_passes.pass_end,
                                             predict_passes.max_elev,
                                             predict_passes.azimuth_at_max,
                                             predict_passes.direction,
                                             decoded_passes.daylight_pass,
                                             decoded_passes.sat_type,
                                             decoded_passes.file_path,
                                             decoded_passes.gain,
                                             decoded_passes.max_snr,
                                             decoded_passes.avg_snr
                                      FROM decoded_passes
                                      INNER JOIN predict_passes
                                        ON predict_passes.pass_start = decoded_passes.pass_start
                                      WHERE decoded_passes.id = ?;");
    $query->bindValue(1, $id);
    $result = $query->execute();
    $row = $result->fetchArray(SQLITE3_ASSOC);

    if ($row === false) {
      http_response_code(404);
      $this->json(array('error' => 'capture not found'));
      return;
    }

    # resolve the enhancement images that actually exist for this capture
    $capture = $this->loadModel('Capture');
    $capture->getEnhancements($id);
    $base_url = $this->baseUrl();
    $images = [];
    foreach ($capture->enhancements as $e) {
      $images[] = $base_url . '/images/' . $row['file_path'] . $e;
    }

    $row['page_url'] = $base_url . '/captures/listImages?pass_id=' . $row['id'];
    $row['images'] = $images;
    $this->json($row);
  }

  public function statusAction($args) {
    $pass = $this->loadModel('Pass');
    $this->json(array(
      'server_time' => time(),
      'current' => $pass->getCurrentCapture(),
      'next' => $pass->getNextPass(),
    ));
  }

  public function rssAction($args) {
    $query = $this->db_conn->query("SELECT decoded_passes.id,
                                           predict_passes.sat_name,
                                           decoded_passes.pass_start,
                                           predict_passes.max_elev,
                                           decoded_passes.daylight_pass,
                                           decoded_passes.sat_type,
                                           decoded_passes.file_path,
                                           decoded_passes.max_snr
                                    FROM decoded_passes
                                    INNER JOIN predict_passes
                                      ON predict_passes.pass_start = decoded_passes.pass_start
                                    ORDER BY decoded_passes.pass_start DESC LIMIT 20;");

    $base_url = $this->baseUrl();
    $items = '';
    while ($row = $query->fetchArray(SQLITE3_ASSOC)) {
      $title = $row['sat_name'] . ' - ' . date('Y-m-d H:i', $row['pass_start']) . ' (' . $row['max_elev'] . '°)';
      $link = $base_url . '/captures/listImages?pass_id=' . $row['id'];
      $description = $row['sat_name'] . ' pass at max elevation ' . $row['max_elev'] . '°';
      if ($row['max_snr'] !== null) {
        $description .= ', peak SNR ' . $row['max_snr'] . ' dB';
      }

      # same representative-thumbnail guess the gallery uses
      if ($row['sat_type'] == 0) {
        $thumb = $row['file_path'] . '-website-thumbnail.jpg';
      } else {
        $thumb = $row['file_path'] . ($row['daylight_pass'] == 1 ? '-MSA.jpg' : '-MCIR.jpg');
      }
      $enclosure = '';
      $thumb_file = Config::THUMB_PATH . '/' . $thumb;
      if (file_exists($thumb_file)) {
        $enclosure = '      <enclosure url="' . htmlspecialchars($base_url . '/images/thumb/' . $thumb, ENT_XML1)
                   . '" length="' . filesize($thumb_file) . '" type="image/jpeg"/>' . "\n";
      }

      $items .= "    <item>\n"
             .  '      <title>' . htmlspecialchars($title, ENT_XML1) . "</title>\n"
             .  '      <link>' . htmlspecialchars($link, ENT_XML1) . "</link>\n"
             .  '      <guid isPermaLink="true">' . htmlspecialchars($link, ENT_XML1) . "</guid>\n"
             .  '      <pubDate>' . date(DATE_RSS, $row['pass_start']) . "</pubDate>\n"
             .  '      <description>' . htmlspecialchars($description, ENT_XML1) . "</description>\n"
             .  $enclosure
             .  "    </item>\n";
    }

    header('Content-Type: application/rss+xml; charset=UTF-8');
    echo '<?xml version="1.0" encoding="UTF-8"?>' . "\n"
       . '<rss version="2.0">' . "\n"
       . "  <channel>\n"
       . '    <title>Raspberry NOAA V2 Captures</title>' . "\n"
       . '    <link>' . htmlspecialchars($base_url . '/captures', ENT_XML1) . "</link>\n"
       . '    <description>Latest weather satellite captures from this ground station</description>' . "\n"
       . $items
       . "  </channel>\n"
       . "</rss>\n";
  }
}

?>
