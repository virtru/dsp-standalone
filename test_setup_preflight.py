"""Validate-only must reject incompatible stacks before changing staged inputs."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SETUP = Path(__file__).with_name("setup_and_validate.sh")


class ValidateOnlyPreflightTests(unittest.TestCase):
    def check_preflight(self, output, exit_code, expected_message, accept=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "setup_and_validate.sh"
            shutil.copyfile(SETUP, script)
            if accept:
                # Stop after the real preflight, before infrastructure work.
                prefix = SETUP.read_text().split("# Prerequisites — delegate", 1)[0]
                script.write_text(prefix + "\necho PREFLIGHT_ACCEPTED\n")
            bundle = root / "virtru-dsp-bundle-2.0.7.0"
            bundle.mkdir()
            cli = bundle / "dsp"
            cli.write_text("#!/bin/sh\nif [ \"$1\" = version ]; then echo 'Version: v2.8.2'; else exit 1; fi\n")
            cli.chmod(0o755)
            generated = root / ".generated"
            (generated / "bin").mkdir(parents=True)
            staged = {
                generated / "license.jwt": b"original-license\n",
                generated / "tagging-pdp-workflows.yaml": b"original-workflow\n",
                generated / "bin" / "tructl": b"original-wrapper\n",
            }
            for path, content in staged.items():
                path.write_bytes(content)
            license_path = root / "replacement.jwt"
            license_path.write_text("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.Zml4dHVyZQ\n")
            tools = root / "tools"
            tools.mkdir()
            docker = tools / "docker"
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['PREFLIGHT_CALLS'], 'a') as f:\n"
                "    f.write(json.dumps(args) + '\\n')\n"
                "if args == ['info']:\n"
                "    print('Operating System: fixture'); sys.exit(0)\n"
                "if args == ['compose', 'exec', '-T', 'dsp', '/usr/bin/dsp', 'version']:\n"
                "    print(os.environ['PREFLIGHT_OUTPUT'])\n"
                "    sys.exit(int(os.environ['PREFLIGHT_EXIT']))\n"
                "sys.exit(1)\n"
            )
            docker.chmod(0o755)
            uname = tools / "uname"
            uname.write_text("#!/bin/sh\ncase \"$1\" in -s) echo Darwin;; -m) echo x86_64;; esac\n")
            uname.chmod(0o755)
            calls = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       PREFLIGHT_CALLS=str(calls), PREFLIGHT_OUTPUT=output,
                       PREFLIGHT_EXIT=str(exit_code))
            env.pop("DSP_LICENSE_FILE", None)
            result = subprocess.run(
                ["bash", str(script), "--validate-only", "--bundle", str(bundle),
                 "--license", str(license_path)],
                env=env, capture_output=True, text=True, timeout=10,
            )
            if accept:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_message, result.stdout + result.stderr)
            for path, content in staged.items():
                self.assertTrue(path.is_file(), str(path))
                self.assertEqual(path.read_bytes(), content)
            self.assertEqual(
                [json.loads(line) for line in calls.read_text().splitlines()],
                [["compose", "exec", "-T", "dsp", "/usr/bin/dsp", "version"]],
            )

    def test_matching_running_versions_are_accepted(self):
        for version in ("v2.8.2", "2.8.2"):
            with self.subTest(version=version):
                self.check_preflight("Version: " + version, 0, "PREFLIGHT_ACCEPTED", accept=True)

    def test_older_running_stack_leaves_inputs_unchanged(self):
        self.check_preflight("Version: v2.7.16", 0, "Run full setup without --validate-only or --no-build")

    def test_unavailable_stack_leaves_inputs_unchanged(self):
        self.check_preflight("service dsp is not running", 1, "Could not verify the running DSP version")

    def test_unrecognized_version_leaves_inputs_unchanged(self):
        self.check_preflight("unknown version output", 0, "Running DSP version unknown")


if __name__ == "__main__":
    unittest.main()
