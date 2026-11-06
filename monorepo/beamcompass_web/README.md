<p align="center">
  <img src="assets/beamcompass.svg" alt="BeamCompass" width="200" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/beamcompass"><img src="https://img.shields.io/badge/GitHub-beamcompass-181717?logo=github" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
</p>

# BeamCompass Web

Self-contained HTML reports for BeamCompass Elixir/OTP architecture analysis.

## Contents

- [Overview](#overview)
- [Getting started](#getting-started)
- [Usage](#usage)
- [Documentation](#documentation)
- [Changelog](CHANGELOG.md)
- [License](LICENSE)

## Overview

Part of [BeamCompass](https://github.com/nshkrdotcom/beamcompass), a conservative
Elixir/OTP architecture navigator using non-executing source AST inspection.
Dynamic dispatch, transitive effects and runtime behavior remain outside the
current analysis guarantees.

## Getting started

Requires Elixir 1.18 or later and a compatible Erlang/OTP release.
From this application's directory:

```sh
mix deps.get
mix compile
```

## Usage

```sh
mix beamcompass.report ../../fixtures/ledger_sample --out /tmp/beamcompass.html
```

This application currently generates static HTML reports and depends on
`beamcompass_core`. Phoenix and LiveView support is deferred.

## Documentation

```sh
mix docs
```

The documentation menu includes this guide, API modules, Mix tasks, the
[changelog](CHANGELOG.md), and the [MIT license](LICENSE).

## Packaging

Build the Hex archive with:

```sh
MIX_ENV=prod mix hex.build
```

Development uses the sibling core application when available. Production and
standalone installs resolve `beamcompass_core` from Hex; publish the core package
before publishing this package.

## License

MIT — Copyright (c) 2026 nshkrdotcom. See [LICENSE](LICENSE).
