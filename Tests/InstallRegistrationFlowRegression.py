#!/usr/bin/env python3
"""Exercise registration receipts on isolated data-only bundles and injected OS observations."""
import base64
from contextlib import contextmanager
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import install_safety as installer
sys.path.insert(0, str(Path(__file__).resolve().parent))
from InstallSafetyRegression import fixture_bundle, node, PAYLOAD


MACL = installer.MACL
OTHER = base64.b64encode(b"fixture.unknown").decode()


class RegistrationCase:
    def __init__(self, root, original, original_macl, change, races, registry_error):
        self.root = root
        self.target = root / "formal/搞积蓄.app"
        self.source = root / "stage.noindex/搞积蓄.app"
        recovery = root / "rollback.noindex/recovery.fixture"
        self.safety = recovery / "Program.noindex" / self.target.name
        self.safety.parent.mkdir(parents=True)
        self.target.parent.mkdir()
        self.binding = recovery / "new-program-identity.json"
        self.receipt = recovery / "original-program.json"
        self.baseline = recovery / "registration-baseline.json"
        self.registration = recovery / "candidate-registration.json"
        self.evidence = recovery / "candidate-registration.noindex"
        self.original = original
        self.original_macl = original_macl
        self.change = change
        self.changes = []
        self.races = list(races)
        self.registry_error = registry_error
        self.started = False
        self.post_reads = 0
        self.returned_trees = []
        self.commands = []
        self.waits = []
        self.signature_reads = 0
        self.real_xattrs = installer.xattrs
        self.real_inventory = installer.inventory
        raw = b"synthetic-exact-original-macl"
        self.macl = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                     "rawBase64": base64.b64encode(raw).decode()}
        self.summary = {k: self.macl[k] for k in ("bytes", "sha256")}
        fixture_bundle(self.source, "4.04", "5")
        self.new_id = node(self.source)
        self.old_id = None
        if original:
            fixture_bundle(self.target, "4.03", "4")
            self.old_id = node(self.target)

    def xattrs(self, path, raw_provenance=False, raw_macl=False):
        observed = self.real_xattrs(path, raw_provenance=raw_provenance, raw_macl=raw_macl)
        if self.original_macl and node(Path(path)) == self.old_id:
            observed[MACL] = copy.deepcopy(self.macl if raw_macl else self.summary)
        return observed

    def inventory(self, path):
        tree = self.real_inventory(path)
        if Path(path) != self.target or node(self.target) != self.new_id:
            return tree
        if not self.started:
            self.before = copy.deepcopy(tree)
            return tree
        self.post_reads += 1
        if self.changes:
            self.change = self.changes.pop(0)
        if self.change in ("macl", "macl-ctime", "wrong-macl", "child-macl"):
            location = PAYLOAD.as_posix() if self.change == "child-macl" else ""
            tree[location]["xattrs"][MACL] = dict(self.summary)
            if self.change == "wrong-macl":
                tree[location]["xattrs"][MACL]["sha256"] = "0" * 64
            if location == "":
                offset = 200 if self.change == "macl-ctime" else 100
                tree[""]["ctimeNS"] = self.before[""]["ctimeNS"] + offset
        elif self.change == "acl":
            tree[PAYLOAD.as_posix()]["aclBase64"] = "dW5rbm93bi1hY2w="
        elif self.change == "other-xattr":
            tree[""]["xattrs"][OTHER] = dict(self.summary)
        elif self.change == "ctime":
            tree[""]["ctimeNS"] = self.before[""]["ctimeNS"] + 100
        elif self.change == "atime":
            tree[""]["atimeNS"] = self.before[""]["atimeNS"] + 100
        if self.races:
            race = self.races.pop(0)
            prior = copy.deepcopy(self.before)
            if race == "already-observed-macl":
                prior[""]["xattrs"][MACL] = dict(self.summary)
            relative = PAYLOAD.as_posix() if race == "child" else ""
            detail = {"operation": "inventory", "root": str(path), "path": str(Path(path) / relative),
                      "relativePath": relative, "completeTree": race != "incomplete",
                      "beforeTree": prior, "afterTree": tree,
                      "diff": [{"path": ["ctimeNS"], "before": self.before[""]["ctimeNS"],
                                "after": tree[""]["ctimeNS"]}]}
            raise installer.InventoryChanged(detail)
        self.returned_trees.append(copy.deepcopy(tree))
        return tree

    def runner(self, argv, **kwargs):
        self.commands.append(argv)
        text, code = "", 0
        if argv == [installer.LSREGISTER, "-f", "-R", str(self.target)]:
            self.started = True
        elif argv == [installer.LSREGISTER, "-dump"]:
            records = []
            if self.target.exists():
                records.append(f"bundle id: 11\nidentifier: {installer.BID}\npath: {self.target}\n")
            if not (self.started and self.registry_error == "missing-witness"):
                records.append(f"bundle id: 12\nidentifier: org.fixture.witness\npath: {self.root / 'witness'}\n")
            text = "----------\n".join(records)
            if self.started and self.registry_error == "ls-empty":
                text = ""
            if self.started and self.registry_error == "ls-failed":
                code = 1
        elif argv == ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", installer.WIDGET_BID]:
            state = "-" if self.registry_error == "pk-disabled" else "+"
            text = f"{state} {installer.WIDGET_BID}(4.04)\n    Path = {self.target / installer.WIDGET}\n"
            if self.registry_error == "pk-empty":
                text = ""
        elif argv not in (
                ["/usr/bin/pluginkit", "-a", str(self.target / installer.WIDGET)],
                [installer.LSREGISTER, "-u", str(self.safety)],
                ["/usr/bin/pluginkit", "-r", str(self.safety / installer.WIDGET)]):
            raise AssertionError("Unexpected injected command " + repr(argv))
        return subprocess.CompletedProcess(argv, code, text, "")

    def signature(self, path):
        if Path(path) != self.target:
            raise AssertionError("Signature hook received an unrelated path")
        self.signature_reads += 1
        return {"fixtureObservation": "stable"}

    def prepare(self):
        installer.bind(self.source, self.binding)
        installer.capture_original(self.target, self.safety, self.receipt)
        installer.registry_baseline(self.target, self.receipt, self.baseline, run=self.runner)
        installer.retain_original(self.target, self.safety, self.receipt)
        installer.promote(self.source, self.target, self.binding)
        self.immutable = {p: p.read_bytes() for p in (
            self.binding, self.receipt, self.baseline,
            self.receipt.parent / "candidate-promotion-intent.json",
            self.receipt.parent / "candidate-promotion.json")}
        self.commands.clear()

    def register(self):
        return installer.register_candidate(self.receipt, self.baseline, run=self.runner,
                                            wait=self.waits.append, sign=self.signature)

    def outcome(self):
        return json.loads((self.evidence / "outcome.json").read_text())

    def samples(self):
        return [json.loads(Path(row["path"]).read_text()) for row in self.outcome()["samples"]]


class InstallRegistrationFlowRegression(unittest.TestCase):
    @contextmanager
    def fixture(self, original=True, original_macl=False, change=None, races=(), registry_error=None):
        with tempfile.TemporaryDirectory(prefix="gaojixu-registration-", suffix=".noindex",
                                         dir="/private/tmp") as directory:
            case = RegistrationCase(Path(directory), original, original_macl, change, races, registry_error)
            with patch.object(installer, "xattrs", side_effect=case.xattrs), \
                    patch.object(installer, "inventory", side_effect=case.inventory):
                case.prepare()
                yield case

    def preserved(self, case):
        for path, raw in case.immutable.items():
            self.assertEqual(path.read_bytes(), raw, str(path))
        self.assertEqual(node(case.target), case.new_id)
        if case.original:
            self.assertEqual(node(case.safety), case.old_id)
        else:
            self.assertFalse(case.safety.exists())

    def rejected(self, case):
        with self.assertRaises((ValueError, OSError)):
            case.register()
        self.assertFalse(case.registration.exists())
        outcome = case.outcome()
        self.assertEqual(outcome["status"], "failed")
        self.assertIn("error", outcome)
        self.preserved(case)

    def test_normal_registration_without_macl(self):
        with self.fixture() as case:
            self.assertTrue(case.register()["candidateRegistered"])
            self.assertEqual(case.waits, [1, 4])
            self.assertEqual(case.signature_reads, 2)
            result = json.loads(case.registration.read_text())
            self.assertFalse(result["proof"]["maclAdded"])
            self.assertIsNone(result["proof"]["expectedMACL"])
            self.assertEqual([s["status"] for s in case.samples()], ["complete"] * 3)
            self.assertTrue(installer.verify_registered(case.receipt)["registeredCandidateVerified"])
            self.preserved(case)

    def test_predeclared_original_macl_is_added_exactly_and_preserved_in_evidence(self):
        with self.fixture(original_macl=True, change="macl") as case:
            self.assertTrue(case.register()["candidateRegistered"])
            intent = json.loads((case.evidence / "intent.json").read_text())
            result = json.loads(case.registration.read_text())
            self.assertEqual(intent["expectedMACL"], case.macl)
            self.assertEqual(result["proof"]["expectedMACL"], case.macl)
            self.assertEqual(result["after"][""]["xattrs"][MACL], case.summary)
            self.assertTrue(result["proof"]["maclAdded"])
            self.assertTrue(installer.verify_registered(case.receipt)["registeredCandidateVerified"])
            self.preserved(case)

    def test_wrong_macl_child_acl_and_unknown_xattr_leave_failure_receipts(self):
        for change in ("wrong-macl", "child-macl", "acl", "other-xattr"):
            with self.subTest(change=change), self.fixture(original_macl=True, change=change) as case:
                self.rejected(case)
                self.assertEqual(len(case.samples()), 1)
                self.assertEqual(case.samples()[0]["status"], "rejected")

    def test_complete_root_race_requires_two_subsequent_stable_samples(self):
        for race in ("complete", "already-observed-macl"):
            with self.subTest(race=race), self.fixture(
                    original_macl=True, change="macl", races=[race]) as case:
                self.assertTrue(case.register()["candidateRegistered"])
                samples = case.samples()
                self.assertEqual([s["status"] for s in samples],
                                 ["exact-macl-addition-race-observed", "complete", "complete"])
                self.assertTrue(samples[0]["error"]["inventory"]["completeTree"])
                self.preserved(case)

    def test_incomplete_or_child_inventory_race_is_rejected_without_retry(self):
        for race in ("incomplete", "child"):
            with self.subTest(race=race), self.fixture(
                    original_macl=True, change="macl", races=[race]) as case:
                self.rejected(case)
                self.assertEqual(case.post_reads, 1)
                self.assertEqual(case.waits, [])

    def test_late_inheritance_exhausts_bound_without_two_stable_inherited_samples(self):
        with self.fixture(original_macl=True) as case:
            case.changes = [None, None, "macl"]
            self.rejected(case)
            self.assertEqual(case.post_reads, 3)
            self.assertEqual(len(case.samples()), 3)
            self.assertEqual(case.waits, [1, 4])
            self.assertIn("two complete stable inventories", case.outcome()["error"]["message"])

    def check_inherited_change_rejected_immediately(self, change):
        for race in (None, "complete", "already-observed-macl"):
            with self.subTest(race=race), self.fixture(
                    original_macl=True, races=[] if race is None else [race]) as case:
                case.changes = ["macl", change, change]
                self.rejected(case)
                self.assertEqual(case.post_reads, 2)
                self.assertEqual(case.waits, [1])
                self.assertEqual(case.changes, [change])
                samples = case.samples()
                first_status = "complete" if race is None else "exact-macl-addition-race-observed"
                self.assertEqual([s["status"] for s in samples], [first_status, "rejected"])
                self.assertEqual(samples[0]["sealedTree"][""]["xattrs"][MACL], case.summary)
                self.assertTrue(samples[1]["inheritanceAlreadySealed"])
                self.assertEqual(sum(args == [installer.LSREGISTER, "-dump"] for args in case.commands),
                                 1 if race is None else 0)

    def test_inherited_macl_deletion_rejected_at_second_sample(self):
        self.check_inherited_change_rejected_immediately(None)

    def test_inherited_macl_second_ctime_change_rejected_at_second_sample(self):
        self.check_inherited_change_rejected_immediately("macl-ctime")

    def test_registry_failures_do_not_turn_a_valid_inventory_into_success(self):
        for error in ("ls-empty", "ls-failed", "missing-witness", "pk-empty", "pk-disabled"):
            with self.subTest(error=error), self.fixture(registry_error=error) as case:
                self.rejected(case)
                self.assertEqual(len(case.samples()), 1)

    def test_completed_receipt_rejects_new_metadata_and_only_tolerates_atime(self):
        with self.fixture() as case:
            case.register()
            case.change = "atime"
            self.assertTrue(installer.verify_registered(case.receipt)["registeredCandidateVerified"])
            for change in ("macl", "ctime", "acl", "other-xattr"):
                with self.subTest(change=change):
                    case.change = change
                    with self.assertRaises(ValueError):
                        installer.verify_registered(case.receipt)
                    self.preserved(case)

    def test_final_verification_records_the_failed_comparison_without_rereading(self):
        with self.fixture() as case:
            real_signature = case.signature
            reads_at_final_signature = []
            inventory_mock = installer.inventory

            def change_after_final_signature(path):
                result = real_signature(path)
                if case.signature_reads == 2:
                    reads_at_final_signature.append(inventory_mock.call_count)
                    case.change = "acl"
                return result

            with patch.object(case, "signature", side_effect=change_after_final_signature):
                with self.assertRaises(installer.TreeDifference) as caught:
                    case.register()
            self.assertEqual(case.post_reads, 4)
            self.assertEqual(len(reads_at_final_signature), 1)
            self.assertEqual(inventory_mock.call_count - reads_at_final_signature[0], 1)
            outcome = case.outcome()
            detail = caught.exception.detail
            self.assertEqual(outcome["phase"], "final-verification")
            self.assertEqual(outcome["status"], "failed")
            self.assertEqual(outcome["error"]["treeDifference"], detail)
            self.assertEqual(detail["operation"], "registration-final-verification")
            self.assertEqual(detail["path"], str(case.target))
            self.assertEqual(detail["expectedTree"], case.samples()[-1]["tree"])
            self.assertEqual(detail["actualTree"], case.returned_trees[-1])
            prior = detail["expectedTree"][PAYLOAD.as_posix()]["aclBase64"]
            self.assertIn({
                "path": [PAYLOAD.as_posix(), "aclBase64"],
                "beforePresent": True, "afterPresent": True,
                "beforeType": "null" if prior is None else "string", "afterType": "string",
                "before": prior, "after": "dW5rbm93bi1hY2w=",
            }, detail["diff"])
            reads_after_failure = inventory_mock.call_count
            self.assertEqual(installer.error_detail(caught.exception), outcome["error"])
            self.assertEqual(inventory_mock.call_count, reads_after_failure)
            self.assertFalse(case.registration.exists())
            self.preserved(case)

    def test_registered_verification_keeps_exact_values_from_its_single_inventory(self):
        with self.fixture() as case:
            case.register()
            completed_bytes = case.registration.read_bytes()
            outcome_bytes = (case.evidence / "outcome.json").read_bytes()
            expected = json.loads(completed_bytes)["after"]
            case.change = "ctime"
            inventory_mock = installer.inventory
            reads_before = inventory_mock.call_count
            with self.assertRaises(installer.TreeDifference) as caught:
                installer.verify_registered(case.receipt)
            self.assertEqual(inventory_mock.call_count - reads_before, 1)
            detail = caught.exception.detail
            self.assertEqual(detail["operation"], "verify-registered")
            self.assertEqual(detail["path"], str(case.target))
            self.assertEqual(detail["expectedTree"], expected)
            self.assertEqual(detail["actualTree"], case.returned_trees[-1])
            self.assertIn({
                "path": ["", "ctimeNS"], "beforePresent": True, "afterPresent": True,
                "beforeType": "int", "afterType": "int", "before": expected[""]["ctimeNS"],
                "after": case.returned_trees[-1][""]["ctimeNS"],
            }, detail["diff"])
            self.assertEqual(installer.error_detail(caught.exception)["treeDifference"], detail)
            self.assertEqual(inventory_mock.call_count - reads_before, 1)
            self.assertEqual(case.registration.read_bytes(), completed_bytes)
            self.assertEqual((case.evidence / "outcome.json").read_bytes(), outcome_bytes)
            self.preserved(case)

    def test_first_install_still_requires_valid_registration_and_metadata(self):
        for change in (None, "macl"):
            with self.subTest(change=change), self.fixture(original=False, change=change) as case:
                if change:
                    self.rejected(case)
                else:
                    result = case.register()
                    self.assertTrue(result["candidateRegistered"])
                    self.assertFalse(result["originalRetained"])
                    self.assertTrue(installer.verify_registered(case.receipt)["registeredCandidateVerified"])
                    self.preserved(case)
                self.assertFalse(any("-u" in args or "-r" in args for args in case.commands))


if __name__ == "__main__":
    unittest.main()
