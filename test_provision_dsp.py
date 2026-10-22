"""Offline provisioning dispatch regression tests: python3 -m unittest -v test_provision_dsp."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("provision_dsp.sh")


class ProvisionDispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.calls = self.directory / "calls.jsonl"
        self.cli = self.directory / "dsp"
        self.cli.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['TEST_CALLS'], 'a') as f:\n"
            "    f.write(json.dumps(args) + '\\n')\n"
            "mode = os.environ['TEST_MODE']\n"
            "modern = args[:2] == ['dev', 'provision']\n"
            "supported = mode == 'both' or (modern and mode == 'modern') or (not modern and mode == 'legacy')\n"
            "if args[-1] == '--help':\n"
            "    if supported:\n"
            "        usage = args[:-1]\n"
            "        if not modern and args[2] == 'keycloak-from-config':\n"
            "            usage = ['keycloak-from-config']\n"
            "        print('Usage:\\n  dsp ' + ' '.join(usage) + ' [flags]')\n"
            "        sys.exit(0)\n"
            "    if mode == 'deprecated':\n"
            "        print('The `tructl provision` command has been deprecated.', file=sys.stderr)\n"
            "        sys.exit(0)\n"
            "    print('unknown command', file=sys.stderr)\n"
            "    sys.exit(1)\n"
            "sys.exit(int(os.environ.get('TEST_WRITE_EXIT', '0')))\n"
        )
        self.cli.chmod(0o755)

    def run_helper(self, mode, operation, *flags, write_exit=0):
        env = dict(os.environ, DSP_CLI=str(self.cli), TEST_CALLS=str(self.calls),
                   TEST_MODE=mode, TEST_WRITE_EXIT=str(write_exit))
        result = subprocess.run(["sh", str(HELPER), operation, *flags], env=env,
                                capture_output=True, text=True, check=False)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        self.calls.unlink(missing_ok=True)
        return result, calls

    def test_modern_commands_preserve_arguments(self):
        for operation in ("policy", "keycloak-from-config"):
            with self.subTest(operation=operation):
                flags = ["-f", "/path with spaces/sample.yaml", "--host", "https://localhost:8080"]
                result, calls = self.run_helper("modern", operation, *flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [["dev", "provision", operation, "--help"],
                                         ["dev", "provision", operation, *flags]])

    def test_legacy_commands(self):
        for operation in ("policy", "keycloak-from-config"):
            with self.subTest(operation=operation):
                result, calls = self.run_helper("legacy", operation, "-n", "company.com")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[-1], ["tructl", "provision", operation, "-n", "company.com"])

    def test_modern_is_preferred_when_both_exist(self):
        result, calls = self.run_helper("both", "policy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], ["dev", "provision", "policy"])
        self.assertEqual(len(calls), 2)

    def test_deprecated_help_success_does_not_trigger_a_write(self):
        result, calls = self.run_helper("deprecated", "policy")
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not support provisioning", result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(call[-1] == "--help" for call in calls))

    def test_failed_write_is_not_retried_and_preserves_exit_code(self):
        result, calls = self.run_helper("both", "policy", write_exit=7)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(len(calls), 2)

    def test_invalid_operation_fails_before_invoking_cli(self):
        result, calls = self.run_helper("both", "invalid")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
