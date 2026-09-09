#!/usr/bin/env python3
"""Build command regressions using disposable projects and real Mach-O files.

Requires Xcode command-line tools and XcodeGen. The xcodebuild process is
replaced with an argument recorder; no app is built, installed, or launched.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MakefileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="candela-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("Makefile", "project.yml"):
            shutil.copy2(ROOT / name, self.root / name)
        checker = ROOT / "tools/build/check-release-markers.sh"
        if checker.exists():
            (self.root / "tools/build").mkdir(parents=True)
            shutil.copy2(checker, self.root / "tools/build")
        for name in ("Candela", "CandelaAppTests", "CandelaKit", "bin"):
            (self.root / name).mkdir()
        (self.root / "Candela/App.swift").write_text("struct App {}\n")
        (self.root / "CandelaAppTests/AppTests.swift").write_text("struct AppTests {}\n")
        self.calls = self.root / "calls.jsonl"
        recorder = self.root / "bin/xcodebuild"
        recorder.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['BUILD_TEST_CALLS'], 'a') as output:\n"
            "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "if 'test' in sys.argv:\n"
            "    print('Test run with 1 test passed after 0.001 seconds.')\n"
        )
        recorder.chmod(0o755)
        self.env = os.environ.copy()
        self.env["PATH"] = str(self.root / "bin") + os.pathsep + self.env["PATH"]
        self.env["BUILD_TEST_CALLS"] = str(self.calls)
        self.run_command(["xcodegen", "generate"])

    def run_command(self, command, *, succeeds=True):
        result = subprocess.run(
            command, cwd=self.root, env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def make(self, *arguments, succeeds=True):
        return self.run_command(["make", "-f", "Makefile", *arguments], succeeds=succeeds)

    def last_build(self):
        return json.loads(self.calls.read_text().splitlines()[-1])

    def sources(self, target_name):
        project = self.run_command([
            "plutil", "-convert", "json", "-o", "-",
            "Candela.xcodeproj/project.pbxproj",
        ])
        objects = json.loads(project.stdout)["objects"]
        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj["name"] == target_name)
        result = set()
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] == "PBXSourcesBuildPhase":
                for file_id in phase["files"]:
                    result.add(objects[objects[file_id]["fileRef"]]["path"])
        return result

    def test_default_signing_preserves_project_settings(self):
        for target in ("build", "release"):
            for options in ([], ["SIGNING=developer-id"]):
                with self.subTest(target=target, options=options):
                    self.make(target, *options)
                    args = self.last_build()
                    self.assertEqual(args[args.index("-derivedDataPath") + 1], "DerivedData")
                    self.assertFalse(any(arg.startswith(("CODE_SIGN", "DEVELOPMENT_TEAM=",
                                                          "OTHER_CODE_SIGN_FLAGS="))
                                         for arg in args), args)

    def test_adhoc_signing_removes_certificate_team_and_timestamp_requirements(self):
        for target, configuration in (("build", "Debug"), ("release", "Release")):
            with self.subTest(target=target):
                self.make(target, "SIGNING=adhoc")
                args = self.last_build()
                for setting in ("CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual",
                                "DEVELOPMENT_TEAM=", "OTHER_CODE_SIGN_FLAGS="):
                    self.assertIn(setting, args)
                self.assertEqual(args[args.index("-configuration") + 1], configuration)
                self.assertEqual(args[args.index("-derivedDataPath") + 1], "DerivedData")

    def test_invalid_signing_fails_before_building(self):
        for value in ("", "ad-hoc", "adhoc developer-id"):
            with self.subTest(value=value):
                result = self.make("build", f"SIGNING={value}", succeeds=False)
                self.assertIn("SIGNING", result.stdout)
                self.assertIn("adhoc", result.stdout)
                self.assertIn("developer-id", result.stdout)
                self.assertFalse(self.calls.exists())

    def test_test_app_uses_only_the_host_free_scheme_without_signing_overrides(self):
        for signing in ("developer-id", "adhoc"):
            with self.subTest(signing=signing):
                self.make("test-app", f"SIGNING={signing}")
                args = self.last_build()
                self.assertEqual(args[args.index("-scheme") + 1], "CandelaAppTests")
                self.assertEqual(args[-1], "test")
                self.assertFalse(any(arg.startswith(("CODE_SIGN", "DEVELOPMENT_TEAM=",
                                                      "OTHER_CODE_SIGN_FLAGS="))
                                     for arg in args), args)

    def test_source_membership_tracks_additions_renames_and_deletions(self):
        original_mtime = (self.root / "project.yml").stat().st_mtime_ns
        app_file = self.root / "Candela/AddedApp.swift"
        test_file = self.root / "CandelaAppTests/AddedTest.swift"
        app_file.write_text("struct AddedApp {}\n")
        test_file.write_text("struct AddedTest {}\n")
        self.make("build")
        self.assertIn("AddedApp.swift", self.sources("Candela"))
        self.assertIn("AddedApp.swift", self.sources("CandelaAppTests"))
        self.assertIn("AddedTest.swift", self.sources("CandelaAppTests"))
        self.assertNotIn("AddedTest.swift", self.sources("Candela"))

        renamed_app = app_file.with_name("RenamedApp.swift")
        renamed_test = test_file.with_name("RenamedTest.swift")
        app_file.rename(renamed_app)
        test_file.rename(renamed_test)
        self.make("release")
        self.assertIn("RenamedApp.swift", self.sources("Candela"))
        self.assertIn("RenamedTest.swift", self.sources("CandelaAppTests"))
        self.assertNotIn("AddedApp.swift", self.sources("Candela"))
        self.assertNotIn("AddedTest.swift", self.sources("CandelaAppTests"))

        renamed_app.unlink()
        renamed_test.unlink()
        self.make("test-app")
        self.assertNotIn("RenamedApp.swift", self.sources("Candela"))
        self.assertNotIn("RenamedApp.swift", self.sources("CandelaAppTests"))
        self.assertNotIn("RenamedTest.swift", self.sources("CandelaAppTests"))
        self.assertEqual((self.root / "project.yml").stat().st_mtime_ns, original_mtime)

    def compile_binary(self, relative_path, message):
        binary = self.root / "DerivedData/Build/Products/Release/Candela.app" / relative_path
        binary.parent.mkdir(parents=True, exist_ok=True)
        source = self.root / "fixture.c"
        source.write_text(f"#include <stdio.h>\nint main(void) {{ puts({json.dumps(message)}); }}\n")
        self.run_command(["clang", str(source), "-o", str(binary)])

    def test_markers_accept_clean_release_and_forward_adhoc_signing(self):
        self.compile_binary("Contents/MacOS/Candela", "Where this display has been lit")
        self.make("markers", "SIGNING=adhoc")
        args = self.last_build()
        self.assertEqual(args[args.index("-configuration") + 1], "Release")
        self.assertIn("CODE_SIGN_IDENTITY=-", args)

    def test_markers_reject_marker_in_nested_macho(self):
        self.compile_binary("Contents/MacOS/Candela", "Where this display has been lit")
        self.compile_binary("Contents/Frameworks/Nested Framework.framework/Nested",
                            "CANDELA_TOOLBAR_STYLE")
        result = self.make("markers", succeeds=False)
        self.assertIn("CANDELA_TOOLBAR_STYLE", result.stdout)
        self.assertIn("Nested Framework.framework/Nested", result.stdout)

    def test_markers_reject_missing_control(self):
        self.compile_binary("Contents/MacOS/Candela", "A clean binary without the control")
        result = self.make("markers", succeeds=False)
        self.assertIn("positive control", result.stdout)

    def test_markers_reject_missing_product(self):
        result = self.make("markers", succeeds=False)
        self.assertIn("no Release binary", result.stdout)

    def test_markers_reject_product_without_machos(self):
        binary = self.root / "DerivedData/Build/Products/Release/Candela.app/Contents/MacOS/Candela"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\necho 'Where this display has been lit'\n")
        binary.chmod(0o755)
        result = self.make("markers", succeeds=False)
        self.assertIn("no Mach-O files", result.stdout)

    def test_markers_reject_inspection_tool_failures(self):
        self.compile_binary("Contents/MacOS/Candela", "Where this display has been lit")
        self.compile_binary("Contents/Frameworks/Nested", "No debug switches here")
        for tool in ("find", "file", "strings"):
            with self.subTest(tool=tool):
                stub = self.root / "bin" / tool
                actual_tool = shutil.which(tool)
                # strings must succeed on the positive control, then fail on
                # an embedded binary that the gate must not silently skip.
                stub.write_text(
                    "#!/bin/bash\n"
                    "if [[ \"$*\" == *Contents/MacOS/Candela* ]]; then\n"
                    f"  exec {actual_tool} \"$@\"\n"
                    "fi\n"
                    "echo 'fixture inspection failure' >&2\nexit 2\n"
                )
                stub.chmod(0o755)
                try:
                    result = self.make("markers", succeeds=False)
                    self.assertIn("fixture inspection failure", result.stdout)
                finally:
                    stub.unlink()

    def test_markers_reject_file_disappearing_before_inspection(self):
        self.compile_binary("Contents/MacOS/Candela", "Where this display has been lit")
        self.compile_binary("Contents/Frameworks/Disappearing", "No debug switches here")
        wrapper = self.root / "bin/file"
        actual_file = shutil.which("file")
        # Use the real file command's handling of a missing path: macOS file
        # reports the error on stdout and exits 0 unless error mode is enabled.
        wrapper.write_text(
            "#!/bin/bash\n"
            "if [[ \"${!#}\" == *Contents/Frameworks/Disappearing ]]; then\n"
            "  rm -- \"${!#}\"\n"
            "fi\n"
            f"exec {actual_file} \"$@\"\n"
        )
        wrapper.chmod(0o755)
        result = self.make("markers", succeeds=False)
        self.assertIn("could not identify file type", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
