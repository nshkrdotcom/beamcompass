#!/bin/sh
# Trusted-application P05A/P05B local release check. Requires ACTUAL Elixir/Mix,
# npm/Chromium/Playwright, and generated core source JSON. Fails rather than skips.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
core="$root/monorepo/beamcompass_core"
web="$root/monorepo/beamcompass_web"
: "${P05_DOCSET_ROOT:=/home/home/p/g/n/brainstorms/nshkrdotcom/docs/20261106/beamcompass/impl_docs}"
: "${P05_SOURCE_FIXTURE:=$root/fixtures/ledger_sample}"
: "${P05_LOG_ROOT:=$(mktemp -d /tmp/beamcompass-p05-verify.XXXXXXXX)}"
: "${P05_WEB_PORT:=4115}"
export P05_LOG_ROOT
export BEAMCOMPASS_CODE_ROOT="$root"
mkdir -p "$P05_LOG_ROOT"
command -v mix >/dev/null || { echo 'UNRUN: mix is absent; do not mark gate passed' >&2; exit 127; }
command -v npm >/dev/null || { echo 'UNRUN: npm is absent' >&2; exit 127; }
command -v chromium >/dev/null || { echo 'UNRUN: chromium is absent' >&2; exit 127; }
# Only trusted sibling Mix apps are ever entered. A scanned target is INPUT DATA.
for app in "$core" "$web"; do
  name=$(basename "$app")
  for item in 'deps.get' 'format --check-formatted' 'compile --warnings-as-errors' 'test' 'credo --strict' 'dialyzer' 'docs'; do
    echo "==> $name: mix $item"
    # Word splitting is intentional for the fixed, literal command list above.
    (cd "$app" && mix $item) >"$P05_LOG_ROOT/$name-$(echo "$item" | tr ' ' '_').log" 2>&1 || {
      echo "FAIL: $name mix $item; see $P05_LOG_ROOT" >&2
      exit 1
    }
  done
done
(
  cd "$web/assets"
  if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
  npm run check
  npm run build
) > "$P05_LOG_ROOT/web-typescript-build.log" 2>&1
[ -s "$web/priv/static/app.js" ] || { echo 'FAIL: Phoenix LiveSocket bundle absent' >&2; exit 1; }
(
  cd "$core"
  mix beamcompass.export "$P05_SOURCE_FIXTURE" --schema 2 --project-id 'p05:measured:source' \
      --out "$P05_LOG_ROOT/snapshot.json" --manifest "$P05_LOG_ROOT/export-manifest.json"
  mix beamcompass.navigator "$P05_LOG_ROOT/snapshot.json" --query 'lens=behavior&budget=64' \
      --out "$P05_LOG_ROOT/headless.json"
  # A second REAL export of a trusted fixture copy exercises architecture time
  # travel. Appending a comment changes source bytes, never executes the target.
  cp -R "$P05_SOURCE_FIXTURE" "$P05_LOG_ROOT/catalog-fixture"
  first_source=$(find "$P05_LOG_ROOT/catalog-fixture" -type f -name '*.ex' | sort | head -n 1)
  [ -n "$first_source" ] || { echo 'FAIL: no .ex fixture for revision test' >&2; exit 1; }
  printf '\n# P05 source-only revision acceptance marker\n' >> "$first_source"
  mix beamcompass.export "$P05_LOG_ROOT/catalog-fixture" --schema 2 \
      --project-id 'p05:measured:source' --out "$P05_LOG_ROOT/alternate.json"
) > "$P05_LOG_ROOT/headless-export.log" 2>&1
mkdir -p "$P05_LOG_ROOT/catalog"
python3 - "$P05_LOG_ROOT/alternate.json" "$P05_LOG_ROOT/catalog" <<'PYREV'
import json, pathlib, shutil, sys
src=pathlib.Path(sys.argv[1]); directory=pathlib.Path(sys.argv[2]); data=json.loads(src.read_text())
shutil.copyfile(src, directory/(data['snapshot_id']+'.json'))
PYREV
export BEAMCOMPASS_NAVIGATOR_CATALOG="$P05_LOG_ROOT/catalog"
export P05_CATALOG_DIR="$P05_LOG_ROOT/catalog"
python3 - "$web/priv/static/app.js" "$P05_LOG_ROOT/bundle-size.json" <<'PYSIZE'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
out.write_text(json.dumps({'asset':'Phoenix LiveSocket bundle','bytes':path.stat().st_size},indent=2)+'\n')
PYSIZE
if [ "${P05_SOURCE_CI_ONLY:-0}" = "1" ]; then
  echo 'SOURCE-CI-ONLY: external parent-docset gate and independent Python consumer remain UNRUN' \
    > "$P05_LOG_ROOT/external-docset-unrun.log"
else
  python3 "$P05_DOCSET_ROOT/tools/consume_navigator.py" "$P05_LOG_ROOT/headless.json" \
    > "$P05_LOG_ROOT/headless-contract.log" 2>&1
  python3 "$P05_DOCSET_ROOT/tools/check_contracts.py" > "$P05_LOG_ROOT/contracts.log" 2>&1
  python3 "$P05_DOCSET_ROOT/tools/phase_scope_gate.py" --phase P05A --require-implemented \
    --code-root "$root" > "$P05_LOG_ROOT/scope.log" 2>&1
  python3 "$P05_DOCSET_ROOT/tools/docsetctl.py" check --code-root "$root" \
    > "$P05_LOG_ROOT/docset-check.log" 2>&1
  python3 -m unittest discover -s "$P05_DOCSET_ROOT/tools" -p 'test_*.py' \
    > "$P05_LOG_ROOT/docset-python.log" 2>&1
fi
cd "$web"
export BEAMCOMPASS_NAVIGATOR_SNAPSHOT="$P05_LOG_ROOT/snapshot.json"
export BEAMCOMPASS_WEB_SERVE=1
export BEAMCOMPASS_WEB_PORT="$P05_WEB_PORT"
# For a local loopback-only test session. Supply your own independent secret in other environments.
: "${BEAMCOMPASS_SECRET_KEY_BASE:=$(python3 -c 'import secrets; print(secrets.token_urlsafe(72))')}"
export BEAMCOMPASS_SECRET_KEY_BASE
mix phx.server > "$P05_LOG_ROOT/live-server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :' EXIT INT TERM
n=0
until curl -fsS "http://127.0.0.1:$P05_WEB_PORT/navigator" >/dev/null 2>&1; do
  n=$((n + 1))
  if [ "$n" -ge 60 ]; then echo 'FAIL: live Phoenix HTTP server not reachable' >&2; exit 1; fi
  sleep 1
done
export P05_SNAPSHOT_PATH="$P05_LOG_ROOT/snapshot.json"
export P05_CORE_APP="$core"
export P05_LIVE_URL="http://127.0.0.1:$P05_WEB_PORT/navigator"
export P05_CHROMIUM="$(command -v chromium)"
export P05_BROWSER_METRICS="$P05_LOG_ROOT/browser-performance.json"
python3 -m unittest discover -s "$web/test/browser" -p 'test_live_acceptance.py' \
  > "$P05_LOG_ROOT/live-browser-acceptance.log" 2>&1
# Fixture display test is supplemental; it never replaces live parity.
python3 -m unittest discover -s "$web/test/browser" -p 'test_navigator_browser.py' \
  > "$P05_LOG_ROOT/chromium-fixture.log" 2>&1
printf 'P05 trusted-app and live-browser checks executed; full release requires separate parent-docset proof. Logs: %s\n' "$P05_LOG_ROOT"
