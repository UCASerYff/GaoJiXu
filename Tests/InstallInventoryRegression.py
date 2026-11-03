#!/usr/bin/env python3
"""Exercise inventory races on data-only /private/tmp fixtures."""
import errno
import hashlib
from contextlib import ExitStack, contextmanager
from pathlib import Path
from types import SimpleNamespace
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import install_safety as installer


class InstallInventoryRegression(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="gaojixu-inventory-", suffix=".noindex", dir="/private/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "data"
        self.root.mkdir()
        self.first = self.root / "a-payload.txt"
        self.last = self.root / "z-payload.txt"
        self.first.write_bytes(b"first synthetic payload")
        self.last.write_bytes(b"last synthetic payload")
        self.first.chmod(0o600)
        self.last.chmod(0o600)

    def assert_changed(self, error, path, field, *, complete=False):
        detail = error.detail
        self.assertEqual(detail["relativePath"], path.relative_to(self.root).as_posix()
                         if path != self.root else "")
        self.assertEqual(detail["path"], str(path))
        self.assertEqual(detail["root"], str(self.root))
        self.assertIs(detail["completeTree"], complete)
        before, after = detail["beforeStat"], detail["afterStat"]
        self.assertNotEqual(before[field], after[field])
        changes = {tuple(change["path"]): change for change in detail["diff"]}
        self.assertEqual(changes[(field,)]["before"], before[field])
        self.assertEqual(changes[(field,)]["after"], after[field])

    def assert_read_error(self, error, path, code):
        detail = error.detail
        self.assertEqual(detail["operation"], "inventory-read")
        self.assertEqual(detail["relativePath"], path.relative_to(self.root).as_posix()
                         if path != self.root else "")
        self.assertEqual(detail["path"], str(path))
        self.assertEqual(detail["root"], str(self.root))
        self.assertEqual(detail["cause"]["errno"], code)
        self.assertIs(detail["completeTree"], False)
        self.assertNotIn("afterTree", detail)

    @contextmanager
    def root_ctime_race(self, *, unreadable=None, change_child=False):
        """Only synthesize root ctime after the last payload was really read."""
        real_lstat = Path.lstat
        real_read = installer.regular_data
        later = False

        def lstat(path, *args, **kwargs):
            observed = real_lstat(path, *args, **kwargs)
            if Path(path) == self.root and later:
                fields = {name: getattr(observed, name) for name in dir(observed)
                          if name.startswith("st_")}
                fields["st_ctime_ns"] += 1
                return SimpleNamespace(**fields)
            return observed

        def read(path):
            nonlocal later
            data = real_read(path)
            if Path(path) == self.last:
                later = True
                if change_child:
                    self.first.chmod(0o640)
            return data

        with ExitStack() as stack:
            stack.enter_context(patch.object(Path, "lstat", lstat))
            stack.enter_context(patch.object(installer, "regular_data", side_effect=read))
            if unreadable is not None:
                name, code = unreadable
                original = getattr(installer, name)

                def attribute(path, *args, **kwargs):
                    if Path(path) == self.root and later:
                        raise OSError(code, "synthetic root reread failure")
                    return original(path, *args, **kwargs)

                stack.enter_context(patch.object(installer, name, side_effect=attribute))
            yield

    def test_unchanged_inventory_contains_complete_real_payloads(self):
        tree = installer.inventory(self.root)
        self.assertEqual(set(tree), {"", self.first.name, self.last.name})
        for path in (self.first, self.last):
            self.assertEqual(tree[path.name]["sha256"],
                             hashlib.sha256(path.read_bytes()).hexdigest())

    def test_mode_change_after_payload_read_reports_exact_relative_stat_diff(self):
        original = installer.regular_data

        def read(path):
            data = original(path)
            if Path(path) == self.first:
                self.first.chmod(0o640)
            return data

        with patch.object(installer, "regular_data", side_effect=read):
            with self.assertRaises(installer.InventoryChanged) as raised:
                installer.inventory(self.root)
        self.assert_changed(raised.exception, self.first, "mode")
        self.assertEqual(raised.exception.detail["observedRow"]["sha256"],
                         hashlib.sha256(self.first.read_bytes()).hexdigest())

    def test_custom_xattr_change_after_payload_read_is_not_accepted(self):
        original = installer.regular_data

        def read(path):
            data = original(path)
            if Path(path) == self.first:
                subprocess.run(
                    ["/usr/bin/xattr", "-w", "com.gaojixu.inventory-regression",
                     "synthetic", str(self.first)], check=True, capture_output=True)
            return data

        with patch.object(installer, "regular_data", side_effect=read):
            with self.assertRaises(installer.InventoryChanged) as raised:
                installer.inventory(self.root)
        self.assert_changed(raised.exception, self.first, "ctimeNS")

    def test_final_stat_pass_rejects_change_to_a_previously_visited_file(self):
        original = installer.regular_data
        seen = []

        def read(path):
            data = original(path)
            seen.append(Path(path).name)
            if Path(path) == self.last:
                self.first.chmod(0o640)
            return data

        with patch.object(installer, "regular_data", side_effect=read):
            with self.assertRaises(installer.InventoryChanged) as raised:
                installer.inventory(self.root)
        self.assertEqual(seen, [self.first.name, self.last.name])
        self.assert_changed(raised.exception, self.first, "mode")

    def test_attribute_read_errors_keep_relative_path_and_errno(self):
        for name, code in (("xattrs", errno.EPERM), ("acl", errno.EACCES),
                           ("birth", errno.EIO)):
            with self.subTest(attribute=name):
                original = getattr(installer, name)

                def attribute(path, *args, **kwargs):
                    if Path(path) == self.first:
                        raise OSError(code, "synthetic attribute read failure")
                    return original(path, *args, **kwargs)

                with patch.object(installer, name, side_effect=attribute):
                    with self.assertRaises(installer.InventoryReadError) as raised:
                        installer.inventory(self.root)
                self.assert_read_error(raised.exception, self.first, code)

    def test_final_stat_read_failure_preserves_node_without_retrying_lstat(self):
        for root_race in (False, True):
            with self.subTest(root_ctime_race=root_race), ExitStack() as stack:
                if root_race:
                    stack.enter_context(self.root_ctime_race())
                original_lstat = Path.lstat
                original_read = installer.regular_data
                read_paths = []
                first_stat_calls = 0
                final_stat_started = False
                failures = 0

                def read(path):
                    data = original_read(path)
                    read_paths.append(Path(path).name)
                    return data

                def lstat(path, *args, **kwargs):
                    nonlocal first_stat_calls, final_stat_started, failures
                    if Path(path) == self.root and self.last.name in read_paths:
                        final_stat_started = True
                    if Path(path) == self.first:
                        first_stat_calls += 1
                        if final_stat_started:
                            failures += 1
                            self.assertEqual(failures, 1, "Failed lstat must not be retried")
                            self.assertEqual(first_stat_calls, 3)
                            self.assertEqual(read_paths, [self.first.name, self.last.name])
                            raise OSError(errno.EACCES, "synthetic final-stat failure")
                    return original_lstat(path, *args, **kwargs)

                stack.enter_context(patch.object(Path, "lstat", lstat))
                stack.enter_context(patch.object(installer, "regular_data", side_effect=read))
                with self.assertRaises(installer.InventoryReadError) as raised:
                    installer.inventory(self.root)
                self.assertEqual(failures, 1)
                self.assertEqual(first_stat_calls, 3)
                self.assert_read_error(raised.exception, self.first, errno.EACCES)

    def test_root_only_ctime_race_reports_complete_trees_but_still_raises(self):
        with self.root_ctime_race():
            with self.assertRaises(installer.InventoryChanged) as raised:
                installer.inventory(self.root)
        self.assert_changed(raised.exception, self.root, "ctimeNS", complete=True)
        before = raised.exception.detail["beforeTree"]
        after = raised.exception.detail["afterTree"]
        self.assertEqual(set(before), {"", self.first.name, self.last.name})
        self.assertEqual(set(after), set(before))
        for path in (self.first, self.last):
            self.assertEqual(before[path.name], after[path.name])
            self.assertEqual(after[path.name]["sha256"],
                             hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(after[""]["xattrs"],
                         installer.xattrs(self.root, raw_provenance=True))
        self.assertEqual(after[""]["aclBase64"], installer.acl(self.root))
        self.assertEqual(after[""]["birth"], installer.birth(self.root))

    def test_failed_root_attribute_reread_never_claims_complete_tree(self):
        for name, code in (("xattrs", errno.EPERM), ("acl", errno.EACCES),
                           ("birth", errno.EIO)):
            with self.subTest(attribute=name):
                with self.root_ctime_race(unreadable=(name, code)):
                    with self.assertRaises(installer.InventoryReadError) as raised:
                        installer.inventory(self.root)
                self.assert_read_error(raised.exception, self.root, code)

    def test_root_ctime_race_with_changed_child_cannot_claim_complete_tree(self):
        with self.root_ctime_race(change_child=True):
            with self.assertRaises(installer.InventoryChanged) as raised:
                installer.inventory(self.root)
        self.assert_changed(raised.exception, self.first, "mode")
        self.assertEqual(raised.exception.detail["operation"], "inventory-final-stat")
        self.assertNotIn("afterTree", raised.exception.detail)


if __name__ == "__main__":
    unittest.main()
