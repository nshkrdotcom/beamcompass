#!/bin/sh
set -eu
for project in beamcompass_core beamcompass_web; do
  echo "==> $project"
  (
    cd "$project"
    mix deps.get
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test
    mix credo --strict
    mix dialyzer
  )
done
