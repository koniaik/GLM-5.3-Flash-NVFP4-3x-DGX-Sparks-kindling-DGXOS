#!/bin/bash
# sparkDash launcher wrapper: stops the TP3 kindling stack
cd "$(dirname "$0")"
exec bash scripts/stop.sh "$@"
