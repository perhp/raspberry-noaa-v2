#!/usr/bin/env python3
#
# Purpose: Print the elevation of the sun over the ground station at a given
#          time. Used to classify captures as day/night passes and to gate
#          Meteor scheduling on a minimum sun elevation.
#
# Input parameters:
#   1. Epoch (unix seconds)
#
# Output: sun elevation in whole degrees, e.g. "-6"
#
# Example:
#   ./sun.py 1613063493

import os
import sys
import time

import ephem

CONFIG_FILE = os.path.expanduser('~/.noaa-v2.conf')

def config_value(key):
  '''
  Read a single KEY=value setting out of ~/.noaa-v2.conf.

  The config is bash-sourceable but its values are not exported, so they are
  not inherited by this process. Parsing the file here also avoids depending
  on envbash, which is unusable from Python 3.13 onwards - it imports the
  'pipes' module that was removed from the standard library.
  '''
  with open(CONFIG_FILE) as f:
    for line in f:
      line = line.strip()
      if line.startswith('#') or '=' not in line:
        continue
      name, _, value = line.partition('=')
      name = name.strip()
      if name.startswith('export '):
        name = name[len('export '):].strip()
      if name != key:
        continue
      value = value.strip()
      if len(value) > 1 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
      return value
  raise KeyError('%s is not set in %s' % (key, CONFIG_FILE))

obs = ephem.Observer()
# strings are read as degrees by ephem (floats would be radians)
obs.lat = str(config_value('LAT'))
obs.long = str(config_value('LON'))
# ephem interprets observer dates as UTC
obs.date = time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(int(sys.argv[1])))

sun = ephem.Sun(obs)
sun.compute(obs)

print(int(float(sun.alt) * 57.2957795))  # rad to deg
