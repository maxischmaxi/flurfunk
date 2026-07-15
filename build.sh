#!/usr/bin/env bash
# Baut Server und Client nach bin/.
# Nutzung: ./build.sh [debug]
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
FLAGS="-o:speed"
if [[ "$MODE" == "debug" ]]; then
	FLAGS="-debug"
fi

mkdir -p bin
echo "== Server =="
odin build src/server -out:bin/ping-server $FLAGS
echo "== Client =="
odin build src/client -out:bin/ping $FLAGS
echo "Fertig: bin/ping-server, bin/ping"
