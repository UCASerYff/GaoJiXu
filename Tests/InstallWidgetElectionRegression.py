#!/usr/bin/env python3
"""Widget election ordering with injected registry observations and data-only bundles."""
import json
from pathlib import Path
import subprocess
import sys
import unittest


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import InstallRegistrationFlowRegression as flow


installer = flow.installer
QUERY = ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", installer.WIDGET_BID]
ELECT = ["/usr/bin/pluginkit", "-e", "use", "-i", installer.WIDGET_BID]


class ElectionObservations:
    def __init__(self, case, mode, initial_state="-"):
        self.case = case
        self.mode = mode
        self.initial_state = initial_state
        self.elections = 0

    def row(self, state, path=None, version="4.04"):
        return (f"{state} {installer.WIDGET_BID}({version})\n"
                f"    Path = {path or self.case.target / installer.WIDGET}\n")

    def run(self, argv, **kwargs):
        if argv == ELECT:
            self.case.commands.append(argv)
            self.elections += 1
            code = 1 if self.mode == "election-failed" else 0
            return subprocess.CompletedProcess(argv, code, "", "")
        if argv != QUERY:
            return self.case.runner(argv, **kwargs)
        self.case.commands.append(argv)
        code = 0
        if self.elections:
            text = self.row("-" if self.mode == "still-disabled" else "+")
        else:
            text = self.row(self.initial_state)
            if self.mode == "duplicate":
                text += self.row(self.initial_state)
            elif self.mode == "wrong-path":
                text = self.row(self.initial_state, self.case.safety / installer.WIDGET)
            elif self.mode == "wrong-version":
                text = self.row(self.initial_state, version="4.03")
            elif self.mode == "empty":
                text = ""
            elif self.mode == "failed-query":
                code = 1
            elif self.mode == "unknown-state":
                text = self.row("=")
            elif self.mode == "unknown-marker":
                text = self.row("?")
        return subprocess.CompletedProcess(argv, code, text, "")


class InstallWidgetElectionRegression(unittest.TestCase):
    def test_explicit_use_prechecks_unique_formal_widget_then_elects_once_and_verifies_plus(self):
        harness = flow.InstallRegistrationFlowRegression()
        for initial in ("-", "", "+"):
            with self.subTest(initial=initial), harness.fixture() as case:
                observations = ElectionObservations(case, "valid", initial)
                result = installer.register_candidate(
                    case.receipt, case.baseline, run=observations.run,
                    wait=case.waits.append, sign=case.signature, widget_election="use")
                self.assertTrue(result["candidateRegistered"])
                self.assertEqual(observations.elections, 1)
                election_index = case.commands.index(ELECT)
                self.assertEqual(case.commands[election_index - 1], QUERY)
                self.assertLess(case.commands.index(
                    ["/usr/bin/pluginkit", "-a", str(case.target / installer.WIDGET)]), election_index - 1)
                self.assertLess(case.commands.index(
                    ["/usr/bin/pluginkit", "-r", str(case.safety / installer.WIDGET)]), election_index - 1)
                self.assertEqual(case.commands.count(QUERY), 4)
                self.assertEqual(json.loads((case.evidence / "intent.json").read_text())
                                 ["requestedWidgetElection"], "use")
                self.assertEqual(case.outcome()["requestedWidgetElection"], "use")
                recorded = [json.loads(Path(item["path"]).read_text())["argv"]
                            for item in case.outcome()["commands"]]
                self.assertEqual(recorded, case.commands)
                self.assertEqual([sample["plugins"][0]["state"] for sample in case.samples()], ["+"] * 3)
                self.assertTrue(installer.verify_registered(case.receipt)["registeredCandidateVerified"])
                harness.preserved(case)

    def test_ambiguous_precheck_failed_or_ineffective_election_and_default_ignore_are_rejected(self):
        harness = flow.InstallRegistrationFlowRegression()
        before_election = ("duplicate", "wrong-path", "wrong-version", "empty", "failed-query",
                           "unknown-state", "unknown-marker")
        for mode in (*before_election, "election-failed", "still-disabled", "default-none"):
            with self.subTest(mode=mode), harness.fixture() as case:
                observations = ElectionObservations(case, mode)
                requested = None if mode == "default-none" else "use"
                with self.assertRaises(ValueError):
                    installer.register_candidate(
                        case.receipt, case.baseline, run=observations.run,
                        wait=case.waits.append, sign=case.signature, widget_election=requested)
                expected_elections = 1 if mode in ("election-failed", "still-disabled") else 0
                self.assertEqual(observations.elections, expected_elections)
                self.assertEqual(case.commands.count(ELECT), expected_elections)
                self.assertFalse(case.registration.exists())
                outcome = case.outcome()
                self.assertEqual(outcome["status"], "failed")
                self.assertEqual(outcome["requestedWidgetElection"], requested)
                self.assertIn("error", outcome)
                if mode in before_election or mode == "election-failed":
                    self.assertEqual(outcome["samples"], [])
                else:
                    self.assertEqual(len(case.samples()), 1)
                    self.assertEqual(case.samples()[0]["status"], "rejected")
                    self.assertEqual(case.samples()[0]["plugins"][0]["state"], "-")
                harness.preserved(case)
        for bad in ("ignore", "default", "arbitrary", ""):
            with self.subTest(unknown_election=bad), harness.fixture() as case:
                observations = ElectionObservations(case, "valid")
                with self.assertRaises(ValueError):
                    installer.register_candidate(
                        case.receipt, case.baseline, run=observations.run,
                        wait=case.waits.append, sign=case.signature, widget_election=bad)
                self.assertEqual(case.commands, [])
                self.assertEqual(case.waits, [])
                self.assertEqual(case.signature_reads, 0)
                self.assertEqual(observations.elections, 0)
                self.assertFalse(case.evidence.exists())
                self.assertFalse(case.registration.exists())
                harness.preserved(case)


if __name__ == "__main__":
    unittest.main()
