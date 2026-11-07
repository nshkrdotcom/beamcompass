# BeamCompass

BeamCompass inspects Elixir/OTP source without executing the inspected project.
It provides source-linked entities, relationships, bounded projections, snapshot
comparison, a standalone CLI, static HTML reports and a Phoenix LiveView navigator.

Requires Elixir 1.20.5 and Erlang/OTP 29.1.2. The two applications under
`monorepo/` are independent Mix projects; there is no root Mix application.

## Scan a project

From `monorepo/beamcompass_core`:

```sh
mix deps.get
mix beamcompass.scan /path/to/project --out /tmp/snapshot.json
mix beamcompass.inventory /path/to/project
mix beamcompass.export /path/to/project --schema 2 \
  --project-id my-project --out /tmp/source.json
```

## Browse

See [the web application](monorepo/beamcompass_web/README.md) for the LiveView
navigator and static HTML reports. See [the core application](monorepo/beamcompass_core/README.md)
for programmatic queries and snapshots.

Source relationships are conservative candidates, not runtime observations.
Dynamic calls and macro-generated definitions can remain unresolved. Anchors
identify source starts; unavailable end positions and omitted records stay explicit.

[MIT License](LICENSE)
