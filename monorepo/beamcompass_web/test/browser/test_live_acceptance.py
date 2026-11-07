"""P05 real local acceptance: live Phoenix HTTP+WebSocket vs independent core CLI.

This is NOT a synthetic test. It deliberately errors if the actual server,
source snapshot, Mix CLI, JavaScript bundle or Chromium cannot be used. Run on
trusted local checkouts after the user has separately committed both A ZIPs.
"""
from __future__ import annotations
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.parse import urlencode, urlsplit, parse_qs
import unittest

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
CORE = Path(os.environ.get('P05_CORE_APP', HERE.parents[2] / 'beamcompass_core')).resolve()
SNAPSHOT = Path(os.environ.get('P05_SNAPSHOT_PATH', '')).resolve()
URL = os.environ.get('P05_LIVE_URL', 'http://127.0.0.1:4115/navigator')
CHROMIUM = os.environ.get('P05_CHROMIUM', '/usr/bin/chromium')
METRICS = Path(os.environ.get('P05_BROWSER_METRICS', '/tmp/beamcompass-p05-browser-metrics.json'))


def persist_model(kind, model):
    directory = METRICS.parent / 'models'
    directory.mkdir(parents=True, exist_ok=True)
    data = json.dumps(model, sort_keys=True, ensure_ascii=False)
    digest = hashlib.sha256(data.encode()).hexdigest()
    (directory / f'{kind}-{digest}.json').write_text(data + '\n')


def headless(query: str, source: Path | None = None) -> dict:
    """A FRESH trusted-core Mix process, not browser-created semantic JSON."""
    with tempfile.TemporaryDirectory(prefix='p05-headless-') as temp:
        out = Path(temp) / 'view.json'
        completed = subprocess.run(
            ['mix', 'beamcompass.navigator', str(source or SNAPSHOT), '--query', query, '--out', str(out)],
            cwd=CORE, capture_output=True, text=True, timeout=90, check=False,
        )
        if completed.returncode:
            raise AssertionError(f'Independent core CLI failed: {completed.stdout} {completed.stderr}')
        result = json.loads(out.read_text())
        persist_model('headless', result)
        return result


def embedded_view(page) -> dict:
    encoded = page.locator('#semantic-stage').get_attribute('data-view')
    if not encoded:
        raise AssertionError('LiveView has no core-generated JSON contract')
    result = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
    persist_model('browser', result)
    return result


def url_with(params: dict) -> str:
    return URL + '?' + urlencode(params)


class RealPhoenixConsumerTests(unittest.TestCase):
    """All of these cases are UNRUN until executed against a real local server."""
    @classmethod
    def setUpClass(cls):
        if not SNAPSHOT.is_file():
            raise AssertionError('P05_SNAPSHOT_PATH must name a REAL exported and validated v2 JSON file')
        if not CORE.joinpath('mix.exs').is_file():
            raise AssertionError('P05_CORE_APP must name the trusted core app, not a scanned target')
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(
            headless=True, executable_path=CHROMIUM, args=['--no-sandbox']
        )
        cls.measurements = []

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()
        METRICS.parent.mkdir(parents=True, exist_ok=True)
        METRICS.write_text(json.dumps({'kind': 'p05-real-live-browser', 'samples': cls.measurements}, indent=2) + '\n')

    def setUp(self):
        self.page = self.browser.new_page(viewport={'width': 1280, 'height': 900})
        self.sockets = []
        self.page.on('websocket', lambda ws: self.sockets.append(ws.url))
        self.page.on('pageerror', lambda err: self.fail(f'Browser JS exception: {err}'))

    def tearDown(self):
        self.page.close()

    def navigate(self, params: dict, expect_stage=True):
        self.page.goto(url_with(params), wait_until='domcontentloaded', timeout=30000)
        if expect_stage:
            self.page.locator('#semantic-stage .stage-card').first.wait_for(timeout=15000)
            self.page.wait_for_function("!!document.querySelector('#semantic-stage[data-live-managed=true]')")
            self.assertTrue(self.sockets, 'LiveView websocket never connected; static HTML alone is insufficient')
        stats = self.page.evaluate('''() => {
          const t = performance.getEntriesByType('navigation')[0];
          return {domContentLoadedMs: t?.domContentLoadedEventEnd ?? null,
            responseEndMs: t?.responseEnd ?? null, transferSizeBytes: t?.transferSize ?? null,
            cardCount: document.querySelectorAll('.stage-card').length,
            viewportWidth: innerWidth, docWidth: document.documentElement.scrollWidth};
        }''')
        self.measurements.append({'query': params, 'browser': stats})
        return embedded_view(self.page) if expect_stage else None

    def test_core_headless_equal_live_and_browser_for_same_exact_source(self):
        q = {'lens': 'effects', 'budget': '64'}
        actual = self.navigate(q)
        expected = headless(urlsplit(self.page.url).query)
        self.assertEqual(actual, expected, 'Source/core model changed between independent process and LiveView')
        cards = self.page.locator('.stage-card')
        self.assertEqual(cards.count(), len(expected['projection']['visible']))
        self.assertEqual(self.page.locator('#preservation-status').inner_text(),
                         f"{expected['projection']['receipt']['status']} · {expected['projection']['receipt']['completeness']}")
        source_counts = self.page.locator('#projection-receipts').inner_text()
        for field in ('visible', 'omitted', 'collapsed', 'unknown'):
            self.assertIn(str(expected['projection']['receipt']['counts'][field]), source_counts)
        self.assertEqual(self.page.locator('#projection-receipts details').count(), 3)
        self.assertIn('source', self.page.locator('.source-warning').inner_text().lower())

    def test_exact_deep_link_stage_click_evidence_and_back_navigation(self):
        original = self.navigate({'lens': 'behavior', 'budget': '128'})
        selected = original['stage']['nodes'][0]
        self.page.locator('.stage-card').first.click()
        self.page.wait_for_function('''id => {
          const drawer=document.querySelector('#source-drawer code');
          return drawer && drawer.textContent===id;
        }''', arg=selected['reference']['object_id'], timeout=15000)
        query = urlsplit(self.page.url).query
        params = parse_qs(query)
        self.assertEqual(params['selected_kind'], [selected['kind']])
        self.assertEqual(params['selected_id'], [selected['reference']['object_id']])
        self.assertEqual(params['snapshot'], [original['snapshot_id']])
        view = embedded_view(self.page)
        self.assertEqual(view, headless(query))
        self.assertEqual(view['drawer']['reference'], selected['reference'])
        for evidence in view['drawer']['evidence']:
            a = evidence['anchor']
            self.assertIn(f"{a['path']}:{a['start_line']}:{a['start_column']}",
                          self.page.locator('#source-drawer').inner_text())
            self.assertIsNone(a['end_line'])
        self.page.reload(wait_until='domcontentloaded')
        self.page.locator('#source-drawer').get_by_text(selected['reference']['object_id']).wait_for()
        self.assertEqual(embedded_view(self.page), view)

    def test_zoom_and_lenses_obey_core_receipts_without_client_inference(self):
        first = self.navigate({'lens': 'state', 'budget': '1'})
        self.assertEqual(first, headless(urlsplit(self.page.url).query))
        self.page.get_by_role('link', name='Increase semantic budget').click()
        self.page.wait_for_function('''() => new URL(location.href).searchParams.get('budget')==='2' ''')
        zoomed = embedded_view(self.page)
        self.assertEqual(zoomed, headless(urlsplit(self.page.url).query))
        self.assertLessEqual(len(first['projection']['visible']), 1)
        self.assertLessEqual(len(zoomed['projection']['visible']), 2)
        self.page.get_by_role('navigation', name='Source view lenses').get_by_role('link', name='Failure').click()
        self.page.wait_for_function('''() => new URL(location.href).searchParams.get('lens')==='failure' ''')
        failure = embedded_view(self.page)
        self.assertEqual(failure, headless(urlsplit(self.page.url).query))
        self.assertEqual(failure['lens'], 'failure')
        self.assertTrue(all('reference' in x for x in failure['projection']['unknown']))

    def test_reject_stale_snapshot_and_missing_source_without_rebinding(self):
        for params, code in [
            ({'snapshot': 'f' * 64, 'lens': 'effects'}, 'snapshot_unavailable'),
            ({'lens': 'behavior', 'selected_kind': 'entity', 'selected_id': 'not-an-object'}, 'selected_target_unavailable'),
            ({'lens': 'behavior', 'focus_kind': 'relation', 'focus_id': 'no-such-source-link'}, 'focus_target_unavailable'),
        ]:
            self.navigate(params, expect_stage=False)
            self.assertEqual(self.page.get_by_role('alert').count(), 1)
            self.assertIn(code, self.page.get_by_role('alert').inner_text())
            self.assertEqual(self.page.locator('.stage-card').count(), 0)
            self.assertEqual(self.page.locator('#semantic-stage').count(), 0)
            self.assertEqual(headless(urlsplit(self.page.url).query)['diagnostics'][0]['code'], code)
        self.navigate({'lens': 'not_a_lens'}, expect_stage=False)
        self.assertIn('unsupported_navigation_lens', self.page.get_by_role('alert').inner_text())
        self.assertEqual(self.page.locator('.stage-card').count(), 0)

    def test_architecture_time_travel_selects_validated_second_revision_without_rebinding(self):
        catalog = Path(os.environ.get('P05_CATALOG_DIR', ''))
        revisions = sorted(catalog.glob('*.json'))
        self.assertEqual(len(revisions), 1, 'Real independently exported alternate revision required')
        alternate = revisions[0]
        selected_id = alternate.stem
        first = self.navigate({'lens':'behavior','budget':'64'})
        self.assertNotEqual(first['snapshot_id'], selected_id)
        links = self.page.get_by_role('navigation', name='Archived source revisions').get_by_role('link')
        self.assertEqual(links.count(), 2)
        links.filter(has_text=selected_id[:12]).click()
        self.page.wait_for_url(f'**snapshot={selected_id}*', timeout=15000)
        self.page.locator('.stage-card').first.wait_for(timeout=15000)
        revised = embedded_view(self.page)
        self.assertEqual(revised['snapshot_id'],selected_id)
        self.assertEqual(revised,headless(urlsplit(self.page.url).query,alternate))
        self.assertIsNone(revised['selection'], 'Revision navigation must not map objects by label')

    def test_question_first_all_lenses_history_and_accessibility_tree(self):
        initial = self.navigate({'lens': 'behavior', 'budget': '128'})
        question = self.page.get_by_role('navigation', name='Source-grounded questions').get_by_role('link').first
        question.click()
        self.page.wait_for_function("new URL(location.href).searchParams.has('focus_id')")
        focused = embedded_view(self.page)
        self.assertIsNotNone(focused['focus'])
        self.assertEqual(focused, headless(urlsplit(self.page.url).query))
        for lens in ('behavior', 'effects', 'state', 'failure'):
            self.page.get_by_role('navigation', name='Source view lenses').get_by_role('link', name=lens.capitalize(), exact=True).click()
            self.page.wait_for_function("lens => new URL(location.href).searchParams.get('lens') === lens", arg=lens)
            self.assertEqual(embedded_view(self.page), headless(urlsplit(self.page.url).query))
        self.page.go_back(wait_until='domcontentloaded')
        self.page.wait_for_function("new URL(location.href).searchParams.get('lens') === 'state'")
        self.page.wait_for_function("JSON.parse(atob(document.querySelector('#semantic-stage').dataset.view.replace(/-/g,'+').replace(/_/g,'/'))).lens === 'state'")
        self.assertEqual(embedded_view(self.page), headless(urlsplit(self.page.url).query))
        tree = self.page.locator('main').aria_snapshot()
        self.assertIn('Source and evidence details', tree)
        self.assertIn('Preservation, omissions & uncertainty', tree)
        self.measurements.append({'accessibility_tree': tree})

    def test_hostile_query_is_inert_and_duplicate_fields_are_rejected(self):
        self.navigate({'selected_kind': 'entity', 'selected_id': '<script>window.p05Injected=true</script>'}, expect_stage=False)
        self.assertIn('selected_target_unavailable', self.page.get_by_role('alert').inner_text())
        self.assertIsNone(self.page.evaluate('window.p05Injected'))
        self.page.goto(URL + '?lens=behavior&lens=effects', wait_until='domcontentloaded')
        self.assertIn('duplicate_navigation_field', self.page.get_by_role('alert').inner_text())
        self.assertEqual(self.page.locator('.stage-card').count(), 0)

    def test_derived_evidence_lineage_selects_exact_input(self):
        snapshot = json.loads(SNAPSHOT.read_text())
        derived = next(e for e in snapshot['evidence'] if e['input_evidence_ids'])
        view = self.navigate({'lens': 'behavior', 'budget': '64',
                              'selected_kind': 'evidence', 'selected_id': derived['id']})
        self.assertEqual(view, headless(urlsplit(self.page.url).query))
        row = next(e for e in view['drawer']['evidence'] if e['id'] == derived['id'])
        parent = row['lineage'][0]
        self.page.locator('#source-drawer').get_by_role('link', name=parent['id'], exact=True).click()
        self.page.wait_for_function("id => new URL(location.href).searchParams.get('selected_id') === id", arg=parent['id'])
        self.page.wait_for_function("id => document.querySelector('#source-drawer code')?.textContent === id", arg=parent['id'])
        self.assertEqual(embedded_view(self.page), headless(urlsplit(self.page.url).query))
        self.assertEqual(embedded_view(self.page)['selection']['object_id'], parent['id'])

    def test_plain_html_fallback_remains_navigable_without_browser_javascript(self):
        context=self.browser.new_context(java_script_enabled=False)
        try:
            page=context.new_page()
            page.goto(url_with({'lens':'behavior','budget':'64'}),wait_until='domcontentloaded')
            self.assertGreater(page.locator('noscript a').count(),0,
                               'Core-generated no-JS stage links are required')
            self.assertEqual(page.get_by_role('main').count(),1)
            self.assertEqual(page.locator('#projection-receipts').count(),1)
        finally:
            context.close()

    def test_axe_wcag2a_aa_in_real_browser_at_desktop_and_mobile(self):
        axe_js = HERE.parents[1] / 'assets' / 'node_modules' / 'axe-core' / 'axe.min.js'
        if not axe_js.is_file():
            self.fail('Real npm axe-core install absent; accessibility gate UNRUN, never green')
        for viewport in ({'width': 1280, 'height': 900}, {'width': 390, 'height': 760}):
            self.page.set_viewport_size(viewport)
            self.navigate({'lens': 'behavior', 'budget': '32'})
            self.page.add_script_tag(path=str(axe_js))
            report = self.page.evaluate('''async () => await axe.run(document, {
              runOnly: {type:'tag', values:['wcag2a','wcag2aa','wcag21a','wcag21aa']}
            })''')
            violations = [f"{v['id']}: {v['description']}" for v in report['violations']]
            self.measurements.append({'accessibility': {'viewport': viewport,
                'violations': violations, 'passes': len(report['passes'])}})
            self.assertEqual(violations, [], 'WCAG A/AA automated audit found violations')

    def test_keyboard_landmarks_mobile_and_no_grand_dependency(self):
        self.navigate({'lens': 'behavior', 'budget': '64'})
        self.assertEqual(self.page.locator('html').get_attribute('lang'), 'en')
        self.assertEqual(self.page.get_by_role('main').count(), 1)
        self.assertEqual(self.page.get_by_role('navigation', name='Source view lenses').count(), 1)
        self.assertEqual(self.page.locator('#source-drawer[aria-label]').count(), 1)
        first = self.page.locator('.stage-card').first
        first.focus()
        self.page.keyboard.press('End')
        self.assertEqual(self.page.locator('.stage-card').last.get_attribute('data-record-key'),
                         self.page.evaluate('document.activeElement.dataset.recordKey'))
        self.page.keyboard.press('Home')
        self.assertEqual(self.page.evaluate('document.activeElement.dataset.recordKey'),
                         first.get_attribute('data-record-key'))
        self.assertNotEqual(first.evaluate('(e)=>getComputedStyle(e).outlineStyle'), 'none')
        self.assertEqual(self.page.locator('a[href*="grand"]').count(), 0)
        self.page.set_viewport_size({'width': 390, 'height': 760})
        self.page.wait_for_function('document.documentElement.scrollWidth<=innerWidth+1', timeout=2000)
        self.assertFalse(self.page.evaluate('document.documentElement.scrollWidth>innerWidth+1'))
        self.page.emulate_media(reduced_motion='reduce')
        self.assertTrue(self.page.evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches"))


if __name__ == '__main__':
    unittest.main(verbosity=2)
