#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for project in beamcompass_core beamcompass_web; do
  echo "==> $project"
  (
    cd "$root/monorepo/$project"
    mix deps.get
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test
    mix credo --strict
    mix dialyzer
  )
done

(cd "$root/fixtures/ledger_sample" && mix format --check-formatted mix.exs "lib/**/*.ex")
