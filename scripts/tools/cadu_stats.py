#!/usr/bin/env python3
"""Report frame-level reception statistics for a SatDump CADU recording.

A CADU file is a flat sequence of fixed 1024-byte frames, each introduced by
the CCSDS sync marker 0x1ACFFC1D and followed by a 6-byte VCDU primary header
carrying the virtual channel id and a 24-bit per-channel frame counter.

That counter is assigned by the spacecraft, so the frames we actually received
can be compared against the span of counters they cover - which tells us
exactly how many frames were lost on the way down, and whether they were lost
steadily (normal, at the weak start/end of a pass) or in one contiguous block
(abnormal, and invisible in the imagery until you notice a black band).

This is worth recording separately because the demodulator's own SNR and BER
readings can look perfectly healthy while frames are going missing.

Prints one line: <received> <expected> <loss_pct> <largest_gap>
A missing, empty or unreadable file reports "0 0 100.0 0" rather than failing,
so a dead capture still yields a usable row.
"""

import sys

SYNC_MARKER = b"\x1a\xcf\xfc\x1d"
CADU_LENGTH = 1024
COUNTER_MODULO = 1 << 24
FILL_VCID = 63

# A counter step larger than this is taken to be a corrupted header rather
# than a genuine gap, and is not counted as lost frames - a whole pass is only
# a few thousand frames, whereas a bad header yields a step in the millions.
MAX_PLAUSIBLE_STEP = 1_000_000


def read_channels(path):
    """Return {vcid: [counter, ...]} in the order the frames were received."""
    with open(path, "rb") as handle:
        data = handle.read()

    channels = {}
    for offset in range(0, len(data) - CADU_LENGTH + 1, CADU_LENGTH):
        if data[offset:offset + 4] != SYNC_MARKER:
            continue
        header = data[offset + 4:offset + 10]
        vcid = ((header[0] << 8) | header[1]) & 0x3F
        counter = (header[2] << 16) | (header[3] << 8) | header[4]
        channels.setdefault(vcid, []).append(counter)
    return channels


def payload_counters(channels):
    """Pick the virtual channel carrying the payload: the busiest one that
    isn't the fill channel, which only pads out the downlink and whose loss
    says nothing about the imagery."""
    candidates = [c for vcid, c in channels.items() if vcid != FILL_VCID]
    if not candidates:
        candidates = list(channels.values())
    return max(candidates, key=len) if candidates else []


def summarise(counters):
    """Return (received, expected, loss_pct, largest_gap)."""
    received = len(counters)
    if received < 2:
        # nothing came down, or too little to establish a span to compare against
        return received, received, 100.0 if received == 0 else 0.0, 0

    expected = 1
    largest_gap = 0
    for previous, current in zip(counters, counters[1:]):
        step = (current - previous) % COUNTER_MODULO
        if step > MAX_PLAUSIBLE_STEP:
            step = 1
        expected += step
        if step - 1 > largest_gap:
            largest_gap = step - 1

    loss_pct = 100.0 * (expected - received) / expected
    return received, expected, loss_pct, largest_gap


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: cadu_stats.py <file.cadu>\n")
        return 2

    try:
        channels = read_channels(sys.argv[1])
    except OSError:
        # no recording at all - report a total loss so the pass still gets a row
        print("0 0 100.0 0")
        return 0

    received, expected, loss_pct, largest_gap = summarise(payload_counters(channels))
    print("%d %d %.1f %d" % (received, expected, loss_pct, largest_gap))
    return 0


if __name__ == "__main__":
    sys.exit(main())
