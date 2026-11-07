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

# Run the trusted formatter from core: entering the scanned target directory
# would load its Mix project even for a format-only command.
(cd "$root/monorepo/beamcompass_core" && mix format --check-formatted \
  "$root/fixtures/ledger_sample/mix.exs" "$root/fixtures/ledger_sample/lib/**/*.ex")
