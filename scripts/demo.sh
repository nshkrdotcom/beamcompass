#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/beamcompass_web"
mix deps.get
mix beamcompass.report "$root/fixtures/ledger_sample" --out "$root/output/ledger-sample.html"
printf 'Wrote %s\n' "$root/output/ledger-sample.html"
