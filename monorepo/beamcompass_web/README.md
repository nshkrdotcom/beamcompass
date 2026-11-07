<p align="center">
  <img src="assets/beamcompass_web.svg" alt="BeamCompass Web logo" width="200">
</p>

# BeamCompass Web

<p>
  <img src="https://img.shields.io/badge/Elixir-1.20.5-4B275F" alt="Elixir 1.20.5">
  <img src="https://img.shields.io/badge/Erlang%2FOTP-29.1.2-A90533" alt="Erlang/OTP 29.1.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"></a>
</p>

BeamCompass Web has a Phoenix LiveView navigator for source graphs and a standalone HTML report for source facts. Neither runs the inspected application.

The navigator reads a saved schema 2 export from [BeamCompass Core](../beamcompass_core/README.md). The report command scans a checkout directly.

## Generate a standalone HTML report

From `monorepo/beamcompass_web`:

```sh
mix deps.get
mix beamcompass.report ../../fixtures/ledger_sample --out ledger-report.html
```

Open `ledger-report.html` in a browser. It contains its own CSS and three views: **behavior**, **effects**, and **state**. Each item shows a source fact ID. Parse issues and inspection limits appear in the report.

Without `--out FILE`, `mix beamcompass.report PATH` writes `beamcompass-report.html`. You do not need LiveView or Node.js to generate it.

You can render an existing fact snapshot programmatically:

```elixir
{:ok, snapshot} = BeamCompass.scan("../../fixtures/ledger_sample")
html = BeamCompassWeb.Report.render(snapshot)
File.write!("ledger-report.html", html)
```

## Start the LiveView navigator

Use Elixir **1.20.5** and Erlang/OTP **29.1.2**, plus Node.js **22** to build browser assets. Start at the repository root.

First, export a typed source graph:

```sh
cd monorepo/beamcompass_core
mix deps.get
mix beamcompass.export ../../fixtures/ledger_sample \
  --schema 2 --project-id ledger-sample --out /tmp/ledger-source.json
```

Then start the web application:

```sh
cd ../beamcompass_web
mix deps.get
cd assets
npm install --no-audit --no-fund
npm run check
npm run build
cd ..

export BEAMCOMPASS_NAVIGATOR_SNAPSHOT=/tmp/ledger-source.json
export BEAMCOMPASS_WEB_SERVE=1
export BEAMCOMPASS_SECRET_KEY_BASE="$(openssl rand -base64 72)"
mix phx.server
```

Open **http://127.0.0.1:4115/navigator**. The server does not listen until you set `BEAMCOMPASS_WEB_SERVE=1`. It binds to `127.0.0.1`.

### Navigate the graph

- **Choose a lens:** Behavior, Effects, State, or Failure. Each lens filters a validated graph; none claims to show observed execution.
- **Start from a question:** Suggested questions are drawn from source triggers. Selecting one focuses the graph on the matching source record.
- **Adjust semantic zoom:** Zoom in or out to change the visible record budget. The default is 16; allowed budgets range from 1 to 256.
- **Select a record:** The drawer shows the exact entity, relation, or evidence identity, its source location and SHA-256, evidence lineage, and related records.
- **Check what is missing:** The receipt lists visible, omitted, collapsed, and unresolved records, along with preservation status and unsatisfied source witnesses.

Stage cards are links. Use the Arrow keys to move between cards, or Home and End to jump to either end. The canvas only draws connections; a link list remains available without JavaScript.

Navigator-generated links include exact project and snapshot IDs, plus the current lens, budget, focus, and selection. To open the default snapshot with a particular lens and budget, use:

```text
/navigator?lens=effects&budget=32
```

For the same view as JSON, run `mix beamcompass.navigator` from Core. The browser draws only relations present in the export.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `BEAMCOMPASS_NAVIGATOR_SNAPSHOT` | Path to the saved, validated schema 2 JSON snapshot | Unset; navigator shows a diagnostic |
| `BEAMCOMPASS_NAVIGATOR_CATALOG` | Optional trusted directory of other exports for the same project | Unset |
| `BEAMCOMPASS_WEB_SERVE` | Set to `1` to enable the HTTP listener | Disabled |
| `BEAMCOMPASS_WEB_PORT` | Listener port when serving | `4115` |
| `BEAMCOMPASS_SECRET_KEY_BASE` | Server secret, at least 64 bytes, required when serving | Required when `BEAMCOMPASS_WEB_SERVE=1` |

Point the snapshot setting at a regular JSON file, not a symlink. The loader rejects files over 16 MiB, malformed JSON, and invalid or unsupported snapshots. The web server reads saved exports; it does not load the target project.

### Browse saved revisions

Set `BEAMCOMPASS_NAVIGATOR_CATALOG` to a directory of trusted exports. Name each file after its 64-character lowercase `snapshot_id`, followed by `.json`:

```text
/path/to/catalog/
  <snapshot_id>.json
  <another_snapshot_id>.json
```

The catalog lists validated snapshots for the current `project_id` and checks at most 64 entries. Opening a revision resets the selection. Missing revisions and records show an error; the navigator never substitutes an object with a similar name.

## Browser assets

Static files are in `priv/static/`; TypeScript sources are in `assets/js/` and `assets/ts/`.

From `monorepo/beamcompass_web/assets`:

```sh
npm install --no-audit --no-fund
npm run check
npm run build
```

`npm run check` type-checks the sources. `npm run build` writes the Phoenix/LiveView client and stage hook to `priv/static/app.js`. The stage checks the view before drawing a relation and never supplies a missing endpoint.

## Development

From `monorepo/beamcompass_web`:

```sh
mix test
mix format --check-formatted
mix docs
```

Read the [Core README](../beamcompass_core/README.md) for scan formats, evidence contracts, snapshot APIs, and the headless navigator. The [repository README](../../README.md) has the short path through both applications.

## License

[MIT License](LICENSE)
