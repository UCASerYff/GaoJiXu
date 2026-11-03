#!/usr/bin/env python3
"""Exercise only the file operations of the macOS install helper on synthetic bundles."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import install_safety as installer
from install_provenance import transition


PAYLOAD = Path("Contents/Resources/fixture.txt")
LINK = Path("Contents/Resources/current")
XATTR = "com.gaojixu.install-regression"


def fixture_bundle(root, version, build):
    """Data-only specimen, with no executable or signature."""
    (root / "Contents/Resources/Empty").mkdir(parents=True)
    widget = root / "Contents/PlugIns/GaoJiXuWidgets.appex/Contents"
    widget.mkdir(parents=True)
    for directory, bundle_id in ((root / "Contents", "com.gaojixu.savings"),
                                 (widget, "com.gaojixu.savings.widgets")):
        (directory / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        }))
    (root / PAYLOAD).write_text("fixture-" + version)
    (root / PAYLOAD).chmod(0o640)
    (root / LINK).symlink_to("fixture.txt")


def node(path):
    info = path.lstat()
    return info.st_dev, info.st_ino


class InstallSafetyRegression(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="gaojixu-install-", suffix=".noindex",
                                                dir="/private/tmp")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.target = self.root / "formal/搞积蓄.app"
        self.source = self.root / "stage.noindex/搞积蓄.app"
        recovery = self.root / "rollback.noindex/recovery.fixture"
        self.safety = recovery / "Program.noindex" / self.target.name
        self.safety.parent.mkdir(parents=True)
        self.binding = recovery / "new-program-identity.json"
        self.receipt = recovery / "original-program.json"
        self.pointer = recovery / "recovery-pointer.json"
        self.quarantine = recovery / "failed-new-program.noindex"
        fixture_bundle(self.target, "4.03", "4")
        fixture_bundle(self.source, "4.04", "5")
        self.old, self.new = node(self.target), node(self.source)
        installer.bind(self.source, self.binding)

    def capture(self):
        installer.capture_original(self.target, self.safety, self.receipt)

    def retain(self):
        installer.retain_original(self.target, self.safety, self.receipt)

    def promote(self):
        installer.promote(self.source, self.target, self.binding)

    def recover(self):
        installer.recover(self.target, self.safety, self.binding, self.quarantine, self.receipt)

    def installed(self):
        self.capture()
        self.retain()
        self.promote()

    def assertAbsent(self, path):
        self.assertFalse(os.path.lexists(path), str(path))

    def test_round_trip_returns_exact_tree_and_quarantines_candidate(self):
        subprocess.run(["/usr/bin/xattr", "-w", XATTR, "original", self.target / PAYLOAD], check=True)
        paths = (Path("."), PAYLOAD, LINK, Path("Contents/Resources/Empty"))
        before = {p: node(self.target / p) for p in paths}
        self.capture()
        self.assertTrue(self.pointer.is_file())
        installer.verify_original(self.target, self.receipt)
        self.retain()
        self.assertAbsent(self.target)
        installer.verify_original(self.safety, self.receipt)
        self.assertEqual(node(self.safety), self.old)
        self.promote()
        self.assertEqual(node(self.target), self.new)
        self.recover()
        self.assertEqual(before, {p: node(self.target / p) for p in paths})
        self.assertEqual((self.target / LINK).readlink(), Path("fixture.txt"))
        self.assertEqual((self.target / PAYLOAD).stat().st_mode & 0o777, 0o640)
        value = subprocess.check_output(["/usr/bin/xattr", "-p", XATTR, self.target / PAYLOAD])
        self.assertEqual(value.rstrip(b"\n"), b"original")
        self.assertEqual(node(self.quarantine), self.new)
        self.assertAbsent(self.safety)
        self.recover()
        self.assertEqual(node(self.target), self.old)
        self.assertEqual(node(self.quarantine), self.new)

    def test_resume_after_old_renamed_before_new_promoted(self):
        self.capture()
        self.retain()
        self.recover()
        self.assertEqual(node(self.target), self.old)
        self.assertEqual(node(self.source), self.new)
        self.assertAbsent(self.safety)
        self.assertAbsent(self.quarantine)

    def test_real_extended_acl_recorded_and_preserved_on_exact_original_file(self):
        payload = self.target / PAYLOAD
        if installer.acl(payload):
            subprocess.run(["/bin/chmod", "-N", payload], check=True)
        self.assertIsNone(installer.acl(payload))
        subprocess.run(["/bin/chmod", "+a", "everyone allow readattr,readextattr,readsecurity",
                        payload], check=True)
        added_acl = installer.acl(payload)
        self.assertTrue(base64.b64decode(added_acl, validate=True))
        old_file = node(payload)
        self.capture()
        row = json.loads(self.receipt.read_text())["tree"][PAYLOAD.as_posix()]
        self.assertEqual(row["aclBase64"], added_acl)
        self.retain()
        self.assertEqual(node(self.safety / PAYLOAD), old_file)
        self.assertEqual(installer.acl(self.safety / PAYLOAD), added_acl)
        self.promote()
        self.recover()
        self.assertEqual(node(self.target), self.old)
        self.assertEqual(node(payload), old_file)
        self.assertEqual(installer.acl(payload), added_acl)
        self.assertEqual(node(self.quarantine), self.new)

    def test_resume_after_candidate_quarantined_before_old_restored(self):
        self.installed()
        installer.exclusive_rename(self.target, self.quarantine)
        self.recover()
        self.assertEqual(node(self.target), self.old)
        self.assertEqual(node(self.quarantine), self.new)
        self.assertAbsent(self.safety)

    def check_resume_pending_original_move(self, restoring):
        if restoring:
            self.installed()
            source, destination, operation = self.safety, self.target, self.recover
        else:
            self.capture()
            source, destination, operation = self.target, self.safety, self.retain
        move_count = len(json.loads(self.pointer.read_text())["moves"])
        real_rename = installer.exclusive_rename
        class PowerLoss(BaseException):
            pass

        def interrupt_after_real_rename(src, dst):
            real_rename(src, dst)
            if (src, dst) == (source, destination):
                raise PowerLoss

        with patch.object(installer, "exclusive_rename", side_effect=interrupt_after_real_rename):
            with self.assertRaises(PowerLoss):
                operation()
        pointer = json.loads(self.pointer.read_text())
        active = pointer["activeMove"]
        intent_bytes = Path(active["path"]).read_bytes()
        self.assertEqual(hashlib.sha256(intent_bytes).hexdigest(), active["sha256"])
        self.assertEqual(json.loads(intent_bytes)["source"], str(source))
        self.assertEqual(len(pointer["moves"]), move_count)
        self.assertEqual(node(destination), self.old)
        operation()
        done = json.loads(self.pointer.read_text())
        self.assertIsNone(done["activeMove"])
        self.assertEqual(len(done["moves"]), move_count + 1)
        complete_bytes = Path(done["moves"][-1]["path"]).read_bytes()
        self.assertEqual(hashlib.sha256(complete_bytes).hexdigest(), done["moves"][-1]["sha256"])
        complete = json.loads(complete_bytes)
        self.assertEqual(complete["intent"], active)
        self.assertEqual(complete["before"], json.loads(intent_bytes)["before"])
        self.assertEqual(complete["proof"], transition(complete["before"], complete["after"]))
        installer.verify_original(destination, self.receipt)
        operation()
        self.assertEqual(json.loads(self.pointer.read_text())["moves"], done["moves"])

    def test_interrupted_original_retention_resolves_durable_move_intent(self):
        self.check_resume_pending_original_move(restoring=False)

    def test_interrupted_original_restoration_resolves_durable_move_intent(self):
        self.check_resume_pending_original_move(restoring=True)

    def test_same_bytes_replacement_at_formal_path_not_retained(self):
        self.capture()
        saved = self.root / "first-original"
        self.target.rename(saved)
        shutil.copytree(saved, self.target, symlinks=True)
        other = node(self.target)
        with self.assertRaises((ValueError, OSError)):
            self.retain()
        self.assertEqual(node(self.target), other)
        self.assertEqual(node(saved), self.old)
        self.assertAbsent(self.safety)

    def test_same_bytes_replacement_at_safety_blocks_recovery_before_quarantine(self):
        self.installed()
        saved = self.root / "first-original"
        self.safety.rename(saved)
        shutil.copytree(saved, self.safety, symlinks=True)
        other = node(self.safety)
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertEqual(node(self.target), self.new)
        self.assertEqual(node(self.safety), other)
        self.assertEqual(node(saved), self.old)
        self.assertAbsent(self.quarantine)

    def test_modified_original_file_blocks_recovery_before_quarantine(self):
        self.installed()
        (self.safety / PAYLOAD).write_text("altered-4.03")
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertEqual(node(self.target), self.new)
        self.assertEqual(node(self.safety), self.old)
        self.assertAbsent(self.quarantine)

    def test_mode_only_change_invalidates_still_bound_original(self):
        self.capture()
        self.retain()
        payload = self.safety / PAYLOAD
        original_file = node(payload)
        payload.chmod(0o600)
        with self.assertRaises((ValueError, OSError)):
            installer.verify_original(self.safety, self.receipt)
        self.assertEqual(node(self.safety), self.old)
        self.assertEqual(node(payload), original_file)

    def test_changed_original_receipt_rejected_even_if_it_decodes_identically(self):
        self.installed()
        with self.receipt.open("ab") as handle:
            handle.write(b"\n")
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertEqual(node(self.target), self.new)
        self.assertEqual(node(self.safety), self.old)
        self.assertAbsent(self.quarantine)

    def test_changed_candidate_binding_rejected_even_if_identity_decodes_identically(self):
        self.installed()
        with self.binding.open("ab") as handle:
            handle.write(b"\n")
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertEqual(node(self.target), self.new)
        self.assertEqual(node(self.safety), self.old)
        self.assertAbsent(self.quarantine)

    def test_resume_request_cannot_redirect_restore_to_another_empty_target(self):
        self.capture()
        self.retain()
        other = self.root / "different-formal" / self.target.name
        other.parent.mkdir()
        with self.assertRaises((ValueError, OSError)):
            installer.recover(other, self.safety, self.binding, self.quarantine, self.receipt)
        self.assertEqual(node(self.safety), self.old)
        self.assertAbsent(other)
        self.assertAbsent(self.quarantine)

    def test_quarantine_cannot_be_redirected_to_another_transaction(self):
        self.installed()
        foreign = self.root / "other-transaction.noindex/failed-new-program.noindex"
        foreign.parent.mkdir()
        with self.assertRaises((ValueError, OSError)):
            installer.recover(self.target, self.safety, self.binding, foreign, self.receipt)
        self.assertEqual(node(self.safety), self.old)
        self.assertEqual(node(self.target), self.new)
        self.assertAbsent(foreign)
        self.assertAbsent(self.quarantine)

    def test_missing_original_blocks_recovery_before_quarantine(self):
        self.installed()
        saved = self.root / "missing-from-recorded-path"
        self.safety.rename(saved)
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertEqual(node(self.target), self.new)
        self.assertEqual(node(saved), self.old)
        self.assertAbsent(self.quarantine)

    def test_formal_symlink_and_quarantine_collision_preserved(self):
        self.capture()
        self.retain()
        self.target.symlink_to(self.source)
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(node(self.source), self.new)
        self.assertEqual(node(self.safety), self.old)
        self.target.unlink()
        self.promote()
        self.quarantine.mkdir()
        foreign = node(self.quarantine)
        with self.assertRaises((ValueError, OSError)):
            self.recover()
        self.assertEqual(node(self.target), self.new)
        self.assertEqual(node(self.safety), self.old)
        self.assertEqual(node(self.quarantine), foreign)

    def test_first_install_without_old_can_only_remove_its_own_candidate(self):
        self.target.rename(self.root / "not-the-formal-target")
        self.capture()
        self.retain()
        self.promote()
        with self.assertRaises((ValueError, OSError)):
            installer.verify_original(self.safety, self.receipt)
        self.recover()
        self.assertAbsent(self.target)
        self.assertAbsent(self.safety)
        self.assertEqual(node(self.quarantine), self.new)

    def check_original_rename_race(self, restoring, obstruct_return):
        if restoring:
            self.installed()
            source, destination, operation = self.safety, self.target, self.recover
        else:
            self.capture()
            source, destination, operation = self.target, self.safety, self.retain
        displaced = self.root / "original-moved-by-fixture"
        intruder = self.root / "unrelated-directory"
        late = self.root / "concurrent-arrival"
        intruder.mkdir()
        late.mkdir()
        alien_id, late_id = node(intruder), node(late)
        real_rename = installer.exclusive_rename
        injected = False

        def swap_before_rename(src, dst):
            nonlocal injected
            if (src, dst) != (source, destination) or injected:
                return real_rename(src, dst)
            injected = True
            source.rename(displaced)
            intruder.rename(source)
            real_rename(source, destination)
            if obstruct_return:
                late.rename(source)

        with patch.object(installer, "exclusive_rename", side_effect=swap_before_rename):
            with self.assertRaises((ValueError, OSError)):
                operation()
        self.assertTrue(injected)
        self.assertEqual(node(displaced), self.old)
        self.assertEqual(node(source), late_id if obstruct_return else alien_id)
        if obstruct_return:
            self.assertEqual(node(destination), alien_id)
        else:
            self.assertAbsent(destination)
        self.assertEqual(node(self.quarantine if restoring else self.source), self.new)

    def test_wrong_directory_moved_during_retention_returns_to_original_location(self):
        self.check_original_rename_race(restoring=False, obstruct_return=False)

    def test_late_formal_occupant_preserved_during_retention_race(self):
        self.check_original_rename_race(restoring=False, obstruct_return=True)

    def test_wrong_directory_moved_during_restore_returns_to_safety_location(self):
        self.check_original_rename_race(restoring=True, obstruct_return=False)

    def test_late_safety_occupant_preserved_during_restore_race(self):
        self.check_original_rename_race(restoring=True, obstruct_return=True)

    def registry_rows(self):
        def row(identifier, path):
            return f"bundle id: 77\nidentifier: {identifier}\npath: {path} (0x10)\n"
        formal = row(installer.BID, self.target)
        witness = row("org.example.fixture", self.root / "witness.noindex")
        return formal, witness, formal + "----------\n" + witness

    def test_registry_baseline_rejects_empty_restricted_and_error_results(self):
        self.capture()
        formal, witness, valid = self.registry_rows()
        baseline = self.receipt.parent / "registration-baseline.json"
        for text, rc in (("", 0), (formal, 0), (witness, 0), (valid, 1)):
            with self.subTest(text=text, rc=rc):
                def query_only(args, **kwargs):
                    self.assertEqual(args, [installer.LSREGISTER, "-dump"])
                    return subprocess.CompletedProcess(args, rc, text, "")
                with self.assertRaises(ValueError):
                    installer.registry_baseline(self.target, self.receipt, baseline, run=query_only)
                self.assertAbsent(baseline)

    def test_retirement_rejects_partial_ls_and_unconfirmed_widget_despite_command_success(self):
        self.capture()
        formal, _, visible = self.registry_rows()
        baseline = self.receipt.parent / "registration-baseline.json"
        def good_baseline(args, **kwargs):
            self.assertEqual(args, [installer.LSREGISTER, "-dump"])
            return subprocess.CompletedProcess(args, 0, visible, "")
        installer.registry_baseline(self.target, self.receipt, baseline, run=good_baseline)
        self.retain()
        self.promote()
        for case in ("missing-witness", "empty-widget", "wrong-widget-path", "disabled-widget",
                     "default-widget", "wrong-version", "mixed-widget-records", "complete-view"):
            with self.subTest(case=case):
                dump_count = 0
                queries = []
                def fake_registry(args, **kwargs):
                    nonlocal dump_count
                    queries.append(args)
                    text = ""
                    if args == [installer.LSREGISTER, "-dump"]:
                        dump_count += 1
                        text = formal if case == "missing-witness" and dump_count > 1 else visible
                    elif args[:2] == ["/usr/bin/pluginkit", "-m"]:
                        official = f"    Path = {self.target / installer.WIDGET}\n"
                        if case == "wrong-widget-path":
                            text = f"+ {installer.WIDGET_BID}(4.04)\n    Path = {self.safety / installer.WIDGET}\n"
                        elif case == "disabled-widget":
                            text = f"- {installer.WIDGET_BID}(4.04)\n" + official
                        elif case == "default-widget":
                            text = f"= {installer.WIDGET_BID}(4.04)\n" + official
                        elif case == "wrong-version":
                            text = f"+ {installer.WIDGET_BID}(4.03)\n" + official
                        elif case == "mixed-widget-records":
                            text = f"+ {installer.WIDGET_BID}(4.04)\n+ org.example.other(4.04)\n" + official
                        elif case == "complete-view":
                            text = f"+ {installer.WIDGET_BID}(4.04)\n" + official
                    else:
                        self.assertIn(args, ([installer.LSREGISTER, "-u", str(self.safety)],
                            ["/usr/bin/pluginkit", "-r", str(self.safety / installer.WIDGET)],
                            ["/usr/bin/pluginkit", "-a", str(self.target / installer.WIDGET)]))
                    return subprocess.CompletedProcess(args, 0, text, "")
                record = self.receipt.parent / (case + ".json")
                def check_registry():
                    return installer.retire_registration(self.safety, self.receipt, baseline, record,
                                                         run=fake_registry, wait=lambda _: None)
                if case == "complete-view":
                    self.assertTrue(check_registry()["backupRegistrationRetired"])
                    status = "exact-backup-path-absent-with-formal-anchors"
                else:
                    with self.assertRaises(ValueError):
                        check_registry()
                    status = "failed"
                self.assertGreaterEqual(dump_count, 2)
                if case != "missing-witness":
                    self.assertTrue(any(q[:2] == ["/usr/bin/pluginkit", "-m"] for q in queries))
                self.assertEqual(json.loads(record.read_text())["status"], status)
                self.assertEqual(node(self.target), self.new)
                self.assertEqual(node(self.safety), self.old)


class OriginalMoveProvenanceRegression(unittest.TestCase):
    """Synthetic inventory rows for the Darwin-owned xattrs. No OS xattr is set here."""
    name = base64.b64encode(b"com.apple.provenance").decode()
    macl = base64.b64encode(b"com.apple.macl").decode()
    child = "Contents/Resources/entry"

    @staticmethod
    def value(raw):
        return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                "rawBase64": base64.b64encode(raw).decode()}

    def setUp(self):
        self.previous = self.value(b"synthetic-pre-rename")
        self.following = self.value(b"synthetic-post-rename")
        self.before = {
            "": {"device": 1, "inode": 100, "mode": 0o40755, "atimeNS": 8, "ctimeNS": 9,
                 "xattrs": {self.name: self.previous}},
            self.child: {"device": 1, "inode": 101, "mode": 0o100644, "atimeNS": 8, "ctimeNS": 9,
                         "xattrs": {self.name: {"bytes": 1, "sha256": hashlib.sha256(b"a").hexdigest()}}},
        }
        self.after = copy.deepcopy(self.before)

    def test_same_inode_root_provenance_change_retains_both_raw_values_and_exact_delta(self):
        self.after[""]["xattrs"][self.name] = self.following
        evidence = transition(self.before, self.after)
        self.assertEqual(evidence["rootProvenanceBefore"], self.previous)
        self.assertEqual(evidence["rootProvenanceAfter"], self.following)
        self.assertEqual(evidence["exactDelta"], [{"path": "", "field": "com.apple.provenance",
                                                  "before": self.previous, "after": self.following}])

    def test_same_name_on_child_and_other_root_xattrs_never_exempted(self):
        for where, key in ((self.child, self.name), ("", self.macl), (self.child, self.macl)):
            with self.subTest(path=where, key=key):
                before = copy.deepcopy(self.before)
                before[where]["xattrs"][key] = {"bytes": 1, "sha256": hashlib.sha256(b"a").hexdigest()}
                after = copy.deepcopy(before)
                after[""]["xattrs"][self.name] = self.following
                after[where]["xattrs"][key]["sha256"] = hashlib.sha256(b"b").hexdigest()
                with self.assertRaises(ValueError):
                    transition(before, after)

    def test_root_provenance_requires_corresponding_verified_raw_bytes(self):
        for field, wrong in (("bytes", 200), ("sha256", "0" * 64), ("rawBase64", "YXNjaWk=")):
            with self.subTest(field=field):
                self.after[""]["xattrs"][self.name] = dict(self.following, **{field: wrong})
                with self.assertRaises(ValueError):
                    transition(self.before, self.after)

    def test_root_provenance_creation_removal_or_inode_change_rejected(self):
        del self.after[""]["xattrs"][self.name]
        with self.assertRaises(ValueError):
            transition(self.before, self.after)
        with self.assertRaises(ValueError):
            transition(self.after, self.before)
        self.after[""]["xattrs"][self.name] = self.following
        self.after[""]["inode"] = 102
        with self.assertRaises(ValueError):
            transition(self.before, self.after)


if __name__ == "__main__":
    unittest.main()
