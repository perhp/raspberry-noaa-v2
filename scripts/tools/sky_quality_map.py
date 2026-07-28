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

import sqlite3
import sys
import time

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
import numpy as np

# webpanel design tokens (see webpanel/public/assets/css/rn2.css) so the plot
# sits in the Stats page rather than on top of it
PANEL = '#ffffff'
INK = '#1b2534'
DIM = '#4f6076'
FAINT = '#7f8da1'
LINE = '#c7d0dd'
LINE_SOFT = '#dde3ec'
RED = '#cc3a2b'

# single-hue sequential ramp, light (weak) to dark (strong)
SNR_CMAP = LinearSegmentedColormap.from_list(
    'rn2_snr', ['#b7cdec', '#5a95d8', '#2268c2', '#123f79'])


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

  plt.rcParams.update({
      'font.family': 'monospace',
      'font.monospace': ['DejaVu Sans Mono', 'monospace'],
      'font.size': 8.5,
  })

  # the page supplies the heading, pass count and explanation, so the plot
  # carries no title of its own
  fig = plt.figure(figsize=(7.2, 7.2), facecolor=PANEL)
  p = fig.add_subplot(111, projection='polar', facecolor=PANEL)
  p.set_theta_zero_location('N')
  p.set_theta_direction(-1)
  # zenith at the center, horizon at the edge
  p.set_rlim(90, 0)
  p.set_yticks(np.arange(90, 0, step=-15))
  p.set_yticklabels(['', '75°', '60°', '45°', '30°', '15°'], color=FAINT)
  p.set_xticks(np.deg2rad(np.arange(0, 360, 45)))
  p.set_xticklabels(['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'], color=DIM)
  p.tick_params(pad=6)
  p.grid(color=LINE_SOFT, linewidth=0.8)
  p.spines['polar'].set_color(LINE)

  scatter = None
  if ok_az:
    scatter = p.scatter(ok_az, ok_el, c=ok_snr, cmap=SNR_CMAP, s=64,
                        edgecolors=INK, linewidths=0.6,
                        label='decoded', zorder=3)
  # hollow, so an unmeasured pass never reads as a weak one on the SNR ramp
  if nosnr_az:
    p.scatter(nosnr_az, nosnr_el, facecolors='none', s=46, edgecolors=FAINT,
              linewidths=0.9, label='decoded, no SNR', zorder=2)
  if fail_az:
    p.scatter(fail_az, fail_el, c=RED, marker='x', s=46, linewidths=1.6,
              label='failed', zorder=4)

  if scatter is not None:
    cbar = fig.colorbar(scatter, ax=p, shrink=0.5, pad=0.06, aspect=16)
    cbar.set_label('PEAK SNR (dB)', color=DIM, labelpad=10)
    cbar.outline.set_edgecolor(LINE)
    cbar.ax.tick_params(color=LINE, labelcolor=FAINT, length=3)
  if nosnr_az or fail_az or ok_az:
    legend = p.legend(loc='lower left', bbox_to_anchor=(-0.08, -0.08),
                      frameon=False, labelcolor=DIM, handletextpad=0.4)
    legend.set_zorder(5)

  plt.savefig(out_file, bbox_inches='tight', dpi=100, facecolor=PANEL)


if __name__ == '__main__':
  main()
