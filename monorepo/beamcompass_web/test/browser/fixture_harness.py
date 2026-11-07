"""Serves a recorded actual P03 projection, adapted for TS display testing only."""
import base64
import json
from pathlib import Path
from urllib.parse import quote

HERE=Path(__file__).resolve().parent
VIEW=HERE/'fixtures/p03b-derived-view.json'
CSS=HERE.parent.parent/'priv/static/navigator.css'
STAGE=HERE.parent.parent/'priv/static/stage.js'


def harness_html(obj):
    payload=base64.urlsafe_b64encode(json.dumps(obj,ensure_ascii=False).encode()).decode().rstrip('=')
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>BeamCompass browser fixture test</title><link rel="stylesheet" href="/assets/navigator.css"></head><body>
    <main class="navigator-layout"><header class="topbar"><div><span class="brand">◈ BEAMCOMPASS</span><span class="eyebrow">P03B RECORDED SOURCE PROJECTION · P05A DISPLAY FIXTURE</span></div><p class="source-warning">source-only; no runtime causality or negative proof</p></header>
    <nav aria-label="Source view lenses" class="lens-nav"><a href="?lens=behavior">Behavior</a><a href="?lens=effects">Effects</a><a href="?lens=state">State</a><a href="?lens=failure">Failure</a></nav>
    <div class="toolbar"><h1>Evidence stage</h1><a aria-label="Increase semantic budget" href="?budget=24">+ Zoom in</a></div>
    <div class="workbench"><section aria-labelledby="stage-heading" class="stage-region"><h2 id="stage-heading">Source records</h2><div id="semantic-stage" data-view="{payload}"></div></section>
    <aside id="source-drawer" aria-label="Source and evidence details" tabindex="-1"><h2>Source &amp; evidence</h2><p>This browser-only fixture does not exercise the Phoenix evidence drawer.</p></aside></div>
    <section id="projection-receipts" class="receipts"><h2>Preservation, omissions &amp; uncertainty</h2><p id="preservation-status">{obj['projection']['receipt']['status']} · {obj['projection']['receipt']['completeness']}</p><p id="counts">Visible: {obj['projection']['receipt']['counts']['visible']} · Omitted: {obj['projection']['receipt']['counts']['omitted']} · Unknown: {obj['projection']['receipt']['counts']['unknown']}</p>
    <details><summary>Unresolved source relations</summary><ul><li>{len(obj['projection']['unknown'])} source-unknown records retained</li></ul></details>
    <details><summary>Omitted source records</summary><ul><li>{len(obj['projection']['omitted'])} explicit budget/focus omissions</li></ul></details></section>
    </main><script type="module">import {{bootStandalone}} from '/assets/stage.js'; bootStandalone();</script></body></html>'''

if __name__=='__main__':
    print(harness_html(json.loads(VIEW.read_text())))
