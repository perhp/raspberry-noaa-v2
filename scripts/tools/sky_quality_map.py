#!/usr/bin/env python3
#
# Purpose: Render a polar "sky quality map" of reception history: every
#          captured pass is plotted at its maximum-elevation position in the
#          sky, colored by the peak SNR SatDump reported for that pass, with
#          failed passes marked separately. Over time this shows which parts
#          of the sky the antenna hears well and where the horizon is
#          obstructed.
#
# Input parameters:
#   1. Path to the panel.db SQLite database
#   2. Output image file
#
# Example:
#   ./scripts/tools/sky_quality_map.py /home/pi/raspberry-noaa-v2/db/panel.db /srv/images/sky-quality-map.png

import datetime
import sqlite3
import sys
import time

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np


def fetch_passes(db_file):
  '''
  Return historic passes as (azimuth_at_max, max_elev, max_snr, failed) rows.
  Passes without an azimuth (predating the azimuth columns) are skipped.
  '''
  conn = sqlite3.connect(db_file, timeout=30)
  rows = conn.execute("""
      SELECT p.azimuth_at_max,
             p.max_elev,
             d.max_snr,
             (d.id IS NULL) AS failed
      FROM predict_passes p
      LEFT JOIN decoded_passes d
        ON p.pass_start = d.pass_start
      WHERE p.pass_start < ?
        AND p.azimuth_at_max IS NOT NULL
        AND p.azimuth_at_max != ''
      """, (int(time.time()),)).fetchall()
  conn.close()
  return rows


def main():
  if len(sys.argv) != 3:
    print("Usage: ./sky_quality_map.py <db_file> <output_image_file>")
    exit(1)

  db_file = sys.argv[1]
  out_file = sys.argv[2]

  rows = fetch_passes(db_file)

  ok_az, ok_el, ok_snr = [], [], []
  nosnr_az, nosnr_el = [], []
  fail_az, fail_el = [], []
  for az, el, snr, failed in rows:
    try:
      az = float(az)
      el = float(el)
    except (TypeError, ValueError):
      continue
    if failed:
      fail_az.append(np.deg2rad(az))
      fail_el.append(el)
    elif snr is None:
      nosnr_az.append(np.deg2rad(az))
      nosnr_el.append(el)
    else:
      ok_az.append(np.deg2rad(az))
      ok_el.append(el)
      ok_snr.append(float(snr))

  fig = plt.figure(figsize=(8, 8))
  p = fig.add_subplot(111, projection='polar')
  p.set_theta_zero_location('N')
  p.set_theta_direction(-1)
  # zenith at the center, horizon at the edge
  p.set_rlim(90, 0)
  p.set_yticks(np.arange(90, 0, step=-15))
  p.set_yticklabels(['', '75°', '60°', '45°', '30°', '15°'])
  p.set_xticks(np.deg2rad(np.arange(0, 360, 45)))
  p.set_xticklabels(['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'])

  if nosnr_az:
    p.scatter(nosnr_az, nosnr_el, c='lightgray', s=40, edgecolors='gray',
              linewidths=0.5, label='decoded (no SNR data)', zorder=2)
  if fail_az:
    p.scatter(fail_az, fail_el, c='red', marker='x', s=40,
              label='failed pass', zorder=3)
  scatter = None
  if ok_az:
    scatter = p.scatter(ok_az, ok_el, c=ok_snr, cmap='viridis', s=60,
                        edgecolors='black', linewidths=0.5,
                        label='decoded pass', zorder=4)

  title = "Reception Quality Sky Map\n"
  title += "each point = max elevation position of a pass\n"
  title += "{} passes through {}".format(
      len(rows), datetime.date.today().strftime('%Y-%m-%d'))
  p.set_title(title, pad=25, fontsize=11)

  if scatter is not None:
    cbar = fig.colorbar(scatter, ax=p, shrink=0.7, pad=0.1)
    cbar.set_label('Peak SNR (dB)')
  if nosnr_az or fail_az or ok_az:
    p.legend(loc='lower left', bbox_to_anchor=(-0.1, -0.12), fontsize=8)

  plt.savefig(out_file, bbox_inches='tight', dpi=100)


if __name__ == '__main__':
  main()
