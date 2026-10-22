#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec python3 tool/build_timeweb.py --mode store "$@"
