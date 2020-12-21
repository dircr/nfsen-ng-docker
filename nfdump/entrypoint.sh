#!/bin/sh

mkdir -p /data/live/router
nfcapd -I router -l /data/live/router -w -S 1 -T all