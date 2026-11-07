"""Actual Chromium/Playwright DOM and keyboard tests over P03B-derived display data.

Does not count as tested Phoenix/LiveView or actual P05 core-produced JSON parity.
"""
import base64
import copy
import hashlib
import json
from pathlib import Path
import unittest
from urllib.parse import parse_qs, urlparse
from playwright.sync_api import sync_playwright
from fixture_harness import harness_html, VIEW, STAGE

# Chromium in this archive environment forbids both HTTP and file navigation.
# page.set_content and native Chromium JS/keyboard/a11y execution are allowed.
# This fixture is still NOT a tested live Phoenix session or P05 core export.
STAGE_SOURCE = STAGE.read_text().replace('export function ', 'function ')


class BrowserAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw=sync_playwright().start()
        cls.browser=cls.pw.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        cls.browser.close();cls.pw.stop()

    def setUp(self):
        self.page=self.browser.new_page(viewport={'width':1280,'height':900})
        fixture=json.loads(VIEW.read_text())
        self.page.set_content(harness_html(fixture))
        self.page.add_style_tag(content=(STAGE.parent/'navigator.css').read_text())
        self.page.add_script_tag(content=STAGE_SOURCE+'\nbootStandalone();')

    def tearDown(self): self.page.close()

    def test_real_browser_renders_source_projection_and_preserved_receipts(self):
        fixture=json.loads(VIEW.read_text())
        self.assertEqual(self.page.locator('#semantic-stage .stage-card').count(),len(fixture['projection']['visible']))
        self.assertEqual(self.page.locator('#semantic-stage canvas[aria-hidden="true"]').count(),1)
        self.assertIn(str(len(fixture['projection']['unknown'])),self.page.locator('#counts').inner_text())
        self.assertIn('unsatisfied',self.page.locator('#preservation-status').inner_text())
        self.assertIn('source-only',self.page.locator('.source-warning').inner_text())
        first=self.page.locator('a.stage-card').first
        url=first.get_attribute('href')
        pinned=parse_qs(urlparse(url).query)
        self.assertEqual(pinned['snapshot'],[fixture['snapshot_id']])
        self.assertEqual(pinned['project'],[fixture['project_id']])
        self.assertEqual(pinned['selected_id'],[fixture['stage']['nodes'][0]['reference']['object_id']])

    def test_keyboard_works_without_mouse_and_focus_has_visible_outline(self):
        first=self.page.locator('a.stage-card').first
        first.focus()
        self.assertTrue(first.evaluate('(x)=>x===document.activeElement'))
        self.page.keyboard.press('ArrowRight')
        self.assertEqual(self.page.locator('a.stage-card').nth(1).get_attribute('data-record-key'),
                         self.page.evaluate('document.activeElement.dataset.recordKey'))
        self.page.keyboard.press('End')
        self.assertEqual(self.page.locator('a.stage-card').last.get_attribute('data-record-key'),
                         self.page.evaluate('document.activeElement.dataset.recordKey'))
        self.assertNotEqual(self.page.evaluate('getComputedStyle(document.activeElement).outlineStyle'),'none')
        self.assertEqual(first.get_attribute('href').startswith('?'),True)

    def test_tampered_identity_is_rejected_in_real_browser_with_no_card(self):
        view=json.loads(VIEW.read_text());bad=copy.deepcopy(view)
        bad['stage']['nodes'][0]['reference']['snapshot_id']='0'*64
        encoded=base64.urlsafe_b64encode(json.dumps(bad).encode()).decode().rstrip('=')
        self.page.evaluate('''payload=>{ const host=document.querySelector('#semantic-stage'); host.dataset.view=payload;
                  mountStage(host); }''',encoded)
        self.page.get_by_role('alert').wait_for()
        self.assertIn('contract unavailable',self.page.get_by_role('alert').inner_text().lower())
        self.assertEqual(self.page.locator('#semantic-stage a.stage-card').count(),0)

    def test_user_text_is_inert_even_with_html_and_event_handler_strings(self):
        view=json.loads(VIEW.read_text());bad=copy.deepcopy(view)
        bad['stage']['nodes'][0]['label']='<img src=x onerror=window.sourceXss=1>'
        encoded=base64.urlsafe_b64encode(json.dumps(bad).encode()).decode().rstrip('=')
        self.page.evaluate('''payload=>{ const host=document.querySelector('#semantic-stage'); host.dataset.view=payload;
                  mountStage(host); }''',encoded)
        self.page.wait_for_function("document.querySelectorAll('#semantic-stage a.stage-card').length>0")
        self.assertEqual(self.page.locator('#semantic-stage img').count(),0)
        self.assertIn('<img src=x',self.page.locator('a.stage-card').first.inner_text())
        self.assertIsNone(self.page.evaluate('window.sourceXss'))

    def test_spoofed_stage_lens_and_budget_links_are_rejected(self):
        view=json.loads(VIEW.read_text());bad=copy.deepcopy(view)
        bad['stage']['nodes'][0]['href']=bad['stage']['nodes'][0]['href'].replace('lens=behavior','lens=failure')
        payload=base64.urlsafe_b64encode(json.dumps(bad).encode()).decode().rstrip('=')
        self.page.evaluate('''payload => { const host=document.querySelector('#semantic-stage');
           host.dataset.view=payload; mountStage(host); }''', payload)
        self.assertIn('contract unavailable', self.page.get_by_role('alert').inner_text().lower())
        self.assertEqual(self.page.locator('a.stage-card').count(),0)
        bad=copy.deepcopy(view)
        bad['navigation']['zoom_in']=bad['navigation']['zoom_in'].replace('snapshot='+view['snapshot_id'],
              'snapshot='+'f'*64)
        payload=base64.urlsafe_b64encode(json.dumps(bad).encode()).decode().rstrip('=')
        self.page.evaluate('''payload => { const host=document.querySelector('#semantic-stage');
           host.dataset.view=payload; mountStage(host); }''', payload)
        self.assertEqual(self.page.locator('a.stage-card').count(),0)

    def test_corrupt_receipt_count_is_not_rendered(self):
        view=json.loads(VIEW.read_text());bad=copy.deepcopy(view)
        bad['projection']['receipt']['counts']['omitted']+=1
        payload=base64.urlsafe_b64encode(json.dumps(bad).encode()).decode().rstrip('=')
        self.page.evaluate('''payload => { const host=document.querySelector('#semantic-stage');
           host.dataset.view=payload; mountStage(host); }''', payload)
        self.assertEqual(self.page.locator('a.stage-card').count(),0)
        self.assertIn('receipt',self.page.get_by_role('alert').inner_text().lower())

    def test_mobile_no_horizontal_overflow_and_aria_landmarks(self):
        self.page.set_viewport_size({'width':390,'height':780})
        self.assertEqual(self.page.get_by_role('main').count(),1)
        self.assertEqual(self.page.get_by_role('navigation',name='Source view lenses').count(),1)
        self.assertEqual(self.page.locator('#source-drawer[aria-label]').count(),1)
        overflow=self.page.evaluate('document.documentElement.scrollWidth > innerWidth + 1')
        self.assertFalse(overflow)

if __name__=='__main__':unittest.main(verbosity=2)
