#!/bin/bash
# sparkDash launcher wrapper: starts the TP3 kindling stack (real script lives in scripts/)
cd "$(dirname "$0")"
exec bash scripts/start.sh "$@"
