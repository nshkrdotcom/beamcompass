"""Mutation source tests; actual recovery MUST execute trusted Mix in local B."""
import json
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import p06_recovery as recovery


class P06RecoveryMutationTests(unittest.TestCase):
    def test_corruption_suite_has_real_old_version_and_trust_mutants(self):
        # Keep tests portable to future committed checkouts: use intentionally
        # self-contained wire-shape fixtures for mutation generator only.
        old1={'schema_version':1,'id':'test','projects':[],'facts':[],'capsules':[],'issues':[]}
        old2={'schema_version':2,'evidence':[{'mode':'source'}], 'snapshot_id':'old'}
        rows=recovery.mutant_versions(recovery.canonical(old1), recovery.canonical(old2))
        self.assertEqual(len(rows),5)
        self.assertEqual({x[1] for x in rows},{'v1','v2'})
        self.assertEqual(json.loads(rows[3][2])['evidence'][0]['mode'],'observed')

    def test_old_mutations_do_not_change_prior_contents(self):
        old1=recovery.canonical({'schema_version':1,'id':'prior','projects':[],'facts':[],
                                 'capsules':[],'issues':[]})
        old2=recovery.canonical({'schema_version':2,'evidence':[{'mode':'source'}],
                                 'snapshot_id':'old'})
        recovery.mutant_versions(old1,old2)
        self.assertEqual(json.loads(old1)['id'],'prior')
        self.assertEqual(json.loads(old2)['evidence'][0]['mode'],'source')

    def test_actual_mix_runner_does_not_call_scanned_target_mix(self):
        text=(Path(__file__).resolve().parents[1]/'p06_recovery.py').read_text()
        self.assertIn("core = source_root / 'monorepo/beamcompass_core'",text)
        self.assertNotIn("cwd=source_root / 'fixtures/ledger_sample'",text)


if __name__=='__main__':
    unittest.main()
