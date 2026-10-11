"""Unit tests for plan_guard, run against real plans captured from the demos (trimmed to the
fields the guard reads). Regenerate fixtures by re-running the demos if the plan format moves.

    python3 -m unittest discover tests
"""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "guard"))
import plan_guard as pg  # noqa: E402

FIX = Path(__file__).with_name("fixtures")
POLICY = json.loads((ROOT / "guard" / "policy.json").read_text())


def plan(name):
    return pg.load_plan(FIX / f"{name}.json")


class Classify(unittest.TestCase):
    def test_replace_in_either_order(self):
        self.assertEqual(pg.classify(["delete", "create"], None), "replace")
        self.assertEqual(pg.classify(["create", "delete"], None), "replace")

    def test_noop_with_previous_address_is_a_move(self):
        self.assertEqual(pg.classify(["no-op"], "module.a.x"), "move")
        self.assertEqual(pg.classify(["no-op"], None), "no-op")


class Evaluate(unittest.TestCase):
    def test_in_place_update_passes(self):
        v = pg.evaluate(plan("safe-change-merge"), POLICY, allow_destroy=False)
        self.assertFalse(v.blocked)
        self.assertEqual(v.warnings, [])

    def test_forced_replacement_of_bucket_blocks_and_names_the_attribute(self):
        v = pg.evaluate(plan("forced-replacement-merge"), POLICY, allow_destroy=False)
        self.assertTrue(v.blocked)
        self.assertEqual(len(v.blocking), 1)
        self.assertIn("module.logs.aws_s3_bucket.this", v.blocking[0])
        self.assertIn("forced by `bucket`", v.blocking[0])

    def test_unprotected_replacements_only_warn(self):
        v = pg.evaluate(plan("forced-replacement-merge"), POLICY, allow_destroy=False)
        self.assertEqual(len(v.warnings), 2)  # versioning + public access block

    def test_label_downgrades_blockers_to_warnings(self):
        v = pg.evaluate(plan("forced-replacement-merge"), POLICY, allow_destroy=True)
        self.assertFalse(v.blocked)
        self.assertEqual(len(v.warnings), 3)

    def test_moved_block_is_not_a_destroy(self):
        changes = plan("module-rename-with-moved-merge")
        self.assertFalse(pg.evaluate(changes, POLICY, allow_destroy=False).blocked)
        self.assertEqual(sum(c.kind == "move" for c in changes.values()), 3)

    def test_count_index_shift_blocks_every_shifted_bucket(self):
        v = pg.evaluate(plan("count-index-shift-merge"), POLICY, allow_destroy=False)
        self.assertEqual(len(v.blocking), 3)


class Stale(unittest.TestCase):
    def test_same_plan_is_not_stale(self):
        p = plan("stale-branch-merge")
        self.assertEqual(pg.stale_drift(p, p), [])

    def test_branch_behind_base_reverts_merged_work(self):
        drift = pg.stale_drift(plan("stale-branch-head"), plan("stale-branch-merge"))
        self.assertEqual(len(drift), 1)
        self.assertIn("aws_s3_bucket.reports", drift[0])
        self.assertIn("delete", drift[0])

    def test_merged_plan_alone_passes(self):
        # The point of the stale check: the merge result is clean, only the branch is not.
        self.assertFalse(pg.evaluate(plan("stale-branch-merge"), POLICY, False).blocked)


class Cli(unittest.TestCase):
    def test_exit_codes_and_marker(self):
        out = FIX.parent / "_comment.md"
        try:
            self.assertEqual(pg.main(["--plan", str(FIX / "safe-change-merge.json"), "--out", str(out)]), 0)
            self.assertTrue(out.read_text().startswith(pg.MARKER))
            self.assertEqual(pg.main(["--plan", str(FIX / "stale-branch-merge.json"),
                                      "--head-plan", str(FIX / "stale-branch-head.json")]), 1)
        finally:
            out.unlink(missing_ok=True)

    def test_rejects_non_plan_json(self):
        bad = FIX.parent / "_bad.json"
        bad.write_text('{"hello": 1}')
        try:
            with self.assertRaises(SystemExit):
                pg.load_plan(bad)
        finally:
            bad.unlink()


if __name__ == "__main__":
    unittest.main()
