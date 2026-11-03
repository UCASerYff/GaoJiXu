#!/usr/bin/env python3
"""Pure inventory comparisons. No filesystem fixtures, App operations, or OS commands."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from install_registration import exact_diff, registration_transition


MACL = base64.b64encode(b"com.apple.macl").decode()
OTHER_XATTR = base64.b64encode(b"fixture.other").decode()
CHILD = "Contents/Resources/fixture.txt"


def attribute(raw):
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
            "rawBase64": base64.b64encode(raw).decode()}


def difference(path, before_present, after_present, before_type, after_type, before, after):
    return {"path": path, "beforePresent": before_present, "afterPresent": after_present,
            "beforeType": before_type, "afterType": after_type, "before": before, "after": after}


class InstallRegistrationRegression(unittest.TestCase):
    def setUp(self):
        self.expected = attribute(b"private-synthetic-original-macl")
        root = {"device": 7, "inode": 10, "mode": 0o40755, "uid": 501, "gid": 20,
                "nlink": 3, "flags": 0, "birth": [100, 1], "mtimeNS": 200,
                "ctimeNS": 300, "atimeNS": 400, "xattrs": {}, "aclBase64": None}
        child = dict(copy.deepcopy(root), inode=11, mode=0o100644, nlink=1,
                     bytes=7, sha256=hashlib.sha256(b"fixture").hexdigest())
        self.before = {"": root, CHILD: child}
        self.after = copy.deepcopy(self.before)

    def add_macl(self, include_raw=False):
        self.after[""]["xattrs"][MACL] = copy.deepcopy(self.expected)
        if not include_raw:
            del self.after[""]["xattrs"][MACL]["rawBase64"]

    def reject(self, before=None, after=None, expected=None):
        before = self.before if before is None else before
        after = self.after if after is None else after
        expected = self.expected if expected is None else expected
        originals = copy.deepcopy((before, after, expected))
        with self.assertRaises(ValueError):
            registration_transition(before, after, expected)
        self.assertEqual(json.dumps((before, after, expected), sort_keys=True),
                         json.dumps(originals, sort_keys=True))

    def test_exact_original_macl_addition_records_all_allowed_changes(self):
        self.add_macl()
        self.after[""]["ctimeNS"] = 301
        self.after[""]["atimeNS"] = 401
        self.after[CHILD]["atimeNS"] = 402
        result = registration_transition(self.before, self.after, self.expected)
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["entryCount"], 2)
        self.assertTrue(result["maclAdded"])
        self.assertEqual(result["expectedMACL"], self.expected)
        self.assertIsNone(result["rootMACLBefore"])
        observed = self.after[""]["xattrs"][MACL]
        self.assertEqual(result["rootMACLAfter"], observed)
        self.assertEqual(result["exactDelta"], [
            difference(["", "atimeNS"], True, True, "int", "int", 400, 401),
            difference(["", "ctimeNS"], True, True, "int", "int", 300, 301),
            difference(["", "xattrs", MACL], False, True, None, "object", None, observed),
            difference([CHILD, "atimeNS"], True, True, "int", "int", 400, 402),
        ])

    def test_addition_without_timestamp_change_is_observable(self):
        self.add_macl(include_raw=True)
        result = registration_transition(self.before, self.after, self.expected)
        self.assertTrue(result["maclAdded"])
        self.assertEqual(result["rootMACLAfter"], self.expected)
        self.assertEqual(len(result["exactDelta"]), 1)

    def test_unchanged_and_atime_only_keep_absent_macl_absent(self):
        result = registration_transition(self.before, self.after, self.expected)
        self.assertFalse(result["maclAdded"])
        self.assertEqual(result["exactDelta"], [])
        self.after[CHILD]["atimeNS"] += 1
        result = registration_transition(self.before, self.after, self.expected)
        self.assertFalse(result["maclAdded"])
        self.assertIsNone(result["rootMACLBefore"])
        self.assertIsNone(result["rootMACLAfter"])
        self.assertEqual(result["exactDelta"], [
            difference([CHILD, "atimeNS"], True, True, "int", "int", 400, 401)])

    def test_existing_macl_may_remain_identical_but_cannot_be_replaced_or_removed(self):
        self.before[""]["xattrs"][MACL] = copy.deepcopy(self.expected)
        self.after = copy.deepcopy(self.before)
        result = registration_transition(self.before, self.after, self.expected)
        self.assertFalse(result["maclAdded"])
        self.assertEqual(result["exactDelta"], [])
        replacement = attribute(b"different-valid-macl")
        self.after[""]["xattrs"][MACL] = replacement
        self.reject()
        self.reject(expected=replacement)
        del self.after[""]["xattrs"][MACL]
        self.reject()
        before = copy.deepcopy(self.before)
        del before[""]["xattrs"][MACL]["rawBase64"]
        self.reject(before=before, after=self.before)

    def test_timestamp_change_requires_the_precise_root_addition(self):
        self.after[""]["ctimeNS"] += 1
        self.reject()
        self.before[""]["xattrs"][MACL] = copy.deepcopy(self.expected)
        self.after[""]["xattrs"][MACL] = copy.deepcopy(self.expected)
        self.reject()

    def test_macl_requires_exact_raw_length_hash_and_typed_fields(self):
        self.add_macl()
        invalid = [
            dict(self.expected, bytes=self.expected["bytes"] + 1),
            dict(self.expected, bytes=True),
            dict(self.expected, sha256="0" * 64),
            dict(self.expected, sha256=self.expected["sha256"].upper()),
            dict(self.expected, rawBase64=base64.b64encode(b"other").decode()),
            dict(self.expected, rawBase64=self.expected["rawBase64"] + "\n"),
            dict(self.expected, unknown="unapproved"),
        ]
        missing_raw = dict(self.expected)
        del missing_raw["rawBase64"]
        self.reject(expected=missing_raw)
        for item in invalid:
            with self.subTest(item=item):
                self.reject(expected=item)
                changed = copy.deepcopy(self.after)
                changed[""]["xattrs"][MACL] = item
                self.reject(after=changed)
        changed = copy.deepcopy(self.after)
        changed[""]["xattrs"][MACL] = attribute(b"valid-but-not-the-original")
        self.reject(after=changed)
        for field, wrong in (("bytes", 200), ("sha256", "0" * 64)):
            changed = copy.deepcopy(self.after)
            changed[""]["xattrs"][MACL][field] = wrong
            self.reject(after=changed)

    def test_macl_addition_does_not_mask_other_metadata_or_content_changes(self):
        self.add_macl()
        for path in ("", CHILD):
            for field, replacement in (
                    ("aclBase64", "bmV3LWFjbA=="), ("mode", 0o40700), ("inode", 99),
                    ("uid", 502), ("flags", 1), ("nlink", 4), ("birth", [101, 1]),
                    ("mtimeNS", 201), ("futureMetadata", {"unrecognized": True})):
                with self.subTest(path=path, field=field):
                    changed = copy.deepcopy(self.after)
                    changed[path][field] = replacement
                    self.reject(after=changed)
        for field, replacement in (("bytes", 8), ("sha256", "f" * 64), ("ctimeNS", 301),
                                   ("linkTargetBase64", "dGFyZ2V0")):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.after)
                changed[CHILD][field] = replacement
                self.reject(after=changed)

    def test_child_macl_and_other_root_attributes_remain_strict(self):
        self.add_macl()
        for path, name in ((CHILD, MACL), ("", OTHER_XATTR), (CHILD, OTHER_XATTR)):
            with self.subTest(path=path, name=name):
                changed = copy.deepcopy(self.after)
                changed[path]["xattrs"][name] = copy.deepcopy(self.expected)
                self.reject(after=changed)
        before = copy.deepcopy(self.before)
        after = copy.deepcopy(self.after)
        before[""]["xattrs"][OTHER_XATTR] = copy.deepcopy(self.expected)
        self.reject(before=before, after=after)

    def test_added_removed_and_renamed_paths_are_rejected(self):
        self.add_macl()
        changed = copy.deepcopy(self.after)
        changed[CHILD + ".extra"] = copy.deepcopy(changed[CHILD])
        self.reject(after=changed)
        del changed[CHILD]
        self.reject(after=changed)
        self.reject(after={"": copy.deepcopy(self.after[""])})
        self.reject(after={CHILD: copy.deepcopy(self.after[CHILD])})

    def test_results_and_inputs_do_not_share_mutable_objects(self):
        self.add_macl()
        originals = copy.deepcopy((self.before, self.after, self.expected))
        result = registration_transition(self.before, self.after, self.expected)
        result["expectedMACL"]["bytes"] = -1
        result["rootMACLAfter"]["rawBase64"] = "changed"
        result["exactDelta"][0]["path"].append("changed")
        result["exactDelta"][0]["after"]["sha256"] = "changed"
        self.assertEqual(json.dumps((self.before, self.after, self.expected), sort_keys=True),
                         json.dumps(originals, sort_keys=True))
        again = registration_transition(self.before, self.after, self.expected)
        self.assertEqual(again["rootMACLAfter"], self.after[""]["xattrs"][MACL])
        self.assertEqual(again["exactDelta"][0]["path"], ["", "xattrs", MACL])

    def test_exact_diff_distinguishes_presence_null_and_numeric_types(self):
        cases = [
            ({}, {"field": None}, difference(["field"], False, True, None, "null", None, None)),
            ({"field": None}, {}, difference(["field"], True, False, "null", None, None, None)),
            ({"field": True}, {"field": 1}, difference(["field"], True, True, "bool", "int", True, 1)),
            ({"field": 1}, {"field": 1.0}, difference(["field"], True, True, "int", "float", 1, 1.0)),
            ({"field": [None]}, {"field": []},
             difference(["field", 0], True, False, "null", None, None, None)),
            ({"field": []}, {"field": [None]},
             difference(["field", 0], False, True, None, "null", None, None)),
        ]
        for before, after, expected in cases:
            with self.subTest(before=before, after=after):
                originals = copy.deepcopy((before, after))
                self.assertEqual(exact_diff(before, after), [expected])
                self.assertEqual((before, after), originals)

    def test_exact_diff_retains_unknown_nested_fields_without_mutating_inputs(self):
        before = {"unknown": {"rows": [{"value": "old"}]}}
        after = {"unknown": {"rows": [{"value": "new"}, {"nullable": None}]}}
        originals = copy.deepcopy((before, after))
        result = exact_diff(before, after)
        self.assertEqual(result, [
            difference(["unknown", "rows", 0, "value"], True, True, "string", "string", "old", "new"),
            difference(["unknown", "rows", 1], False, True, None, "object", None, {"nullable": None}),
        ])
        result[1]["after"]["nullable"] = "mutated"
        self.assertEqual((before, after), originals)


if __name__ == "__main__":
    unittest.main()
