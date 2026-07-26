#!/usr/bin/env python3
#
# Purpose: Predict upcoming passes of a satellite over the ground station
#          using the TLE data downloaded by schedule.sh. Replaces the old
#          external 'predict' binary (and with it, the 9-character username
#          and TLE-path limitations that tool imposed).
#
# Input parameters:
#   1. TLE file
#   2. Satellite name as listed in the TLE file (e.g. "NOAA 18")
#   3. Start epoch (unix seconds) to search from
#   4. End epoch (unix seconds) - only passes ending at or before this time are printed
#   5. Ground station latitude (decimal degrees, south negative)
#   6. Ground station longitude (decimal degrees, west negative)
#   7. Ground station altitude (meters)
#
# Output: one pass per line, all values integers (angles in degrees):
#   <start_epoch> <end_epoch> <max_elevation> <start_azimuth> <azimuth_at_max_elevation>
#
# Example:
#   ./pass_predict.py tmp/orbit.tle "NOAA 18" 1617422399 1618027199 40.712776 -74.005974 0

import calendar
import datetime
import sys
from math import degrees

import ephem

def getSat(filename, sat_name):
  '''
  Load specific satellite TLE data from a file and return
  an ephem object (or NoneType if failure)
  '''
  with open(filename) as f:
    lines = [line.strip() for line in f if line.strip()]

  for i in range(len(lines) - 2):
    if lines[i] == sat_name and lines[i+1].startswith('1 ') and lines[i+2].startswith('2 '):
      return ephem.readtle(lines[i], lines[i+1], lines[i+2])

  return None

def toEpoch(date):
  '''
  Convert an ephem.Date to unix epoch seconds (UTC)
  '''
  return calendar.timegm(date.datetime().timetuple())

def main():
  if len(sys.argv) != 8:
    print("Usage: ./pass_predict.py <tle_file> <satellite_name> <start_epoch> <end_epoch> <latitude> <longitude> <altitude>", file=sys.stderr)
    exit(1)

  tle_file = sys.argv[1]
  sat_name = sys.argv[2]
  start_epoch = int(sys.argv[3])
  end_epoch = int(sys.argv[4])
  latitude = sys.argv[5]
  longitude = sys.argv[6]
  altitude = float(sys.argv[7])

  sat = getSat(tle_file, sat_name)
  if sat is None:
    print("Could not find satellite {} in TLE file {}".format(sat_name, tle_file), file=sys.stderr)
    exit(1)

  # establish ground station coordinates - note that lat/lon MUST be passed
  # as strings so ephem interprets them as degrees rather than radians;
  # pressure 0 disables atmospheric refraction (matching 'predict' output)
  gs = ephem.Observer()
  gs.lat = str(latitude)
  gs.lon = str(longitude)
  gs.elevation = altitude
  gs.pressure = 0

  current_epoch = start_epoch
  while current_epoch < end_epoch:
    gs.date = datetime.datetime.fromtimestamp(current_epoch, datetime.timezone.utc).replace(tzinfo=None)

    try:
      rise_time, rise_az, max_time, max_alt, set_time, set_az = gs.next_pass(sat)
    except ValueError:
      # satellite never rises (or never sets) for this ground station
      break

    if max_time is None or set_time is None:
      break

    # a satellite already above the horizon reports no rise time - treat the
    # search time as the start of the pass
    if rise_time is None:
      rise_time = gs.date
      gs.date = rise_time
      sat.compute(gs)
      rise_az = sat.az

    pass_start = toEpoch(rise_time)
    pass_end = toEpoch(set_time)

    if pass_end <= current_epoch:
      # guard against a stuck search window
      current_epoch += 60
      continue

    if pass_end > end_epoch:
      break

    # azimuth at the point of maximum elevation
    gs.date = max_time
    sat.compute(gs)
    azimuth_at_max = degrees(sat.az)

    print("{} {} {} {} {}".format(pass_start,
                                  pass_end,
                                  round(degrees(max_alt)),
                                  round(degrees(rise_az)),
                                  round(azimuth_at_max)))

    current_epoch = pass_end + 60

if __name__ == '__main__':
  main()
