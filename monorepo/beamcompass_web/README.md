# BeamCompass Web

Phoenix LiveView navigation and standalone HTML reports over BeamCompass source data.
Requires Elixir 1.20.5, Erlang/OTP 29.1.2 and Node.js 22 for browser assets.

## Static report

From this application's directory:

```sh
mix deps.get
mix beamcompass.report /path/to/project --out /tmp/report.html
```

## Live navigator

Export a typed source snapshot with the core application first. Then:

```sh
mix deps.get
cd assets
npm ci --no-audit --no-fund
npm run check
npm run build
cd ..
export BEAMCOMPASS_NAVIGATOR_SNAPSHOT=/absolute/path/to/source.json
export BEAMCOMPASS_WEB_SERVE=1
export BEAMCOMPASS_SECRET_KEY_BASE="$(openssl rand -base64 72)"
mix phx.server
```

Open `http://127.0.0.1:4115/navigator`. The server is disabled by default and
listens on loopback when enabled. `BEAMCOMPASS_WEB_PORT` changes the port.

The navigator displays core-owned source views, exact evidence links, semantic
zoom, keyboard navigation and explicit omissions. Optional
`BEAMCOMPASS_NAVIGATOR_CATALOG` points to a trusted directory of same-project
V2 snapshots named `<snapshot_id>.json` for revision navigation.

The UI does not infer runtime behavior or execute the inspected project's code.
Missing snapshots and invalid selections produce diagnostics.

Generate API documentation with `mix docs`.

[MIT License](LICENSE)
