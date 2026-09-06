#!/usr/bin/env python3
"""Focused, dependency-free unit tests for the release audit helpers.

These tests intentionally exercise path and policy logic only.  They do not
need a Mach-O executable, a signing identity, or the Sparkle private key.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("audit_release", SCRIPT_DIR / "audit-release.py")
if _spec is None or _spec.loader is None:
    raise SystemExit("could not load audit-release.py")
audit = importlib.util.module_from_spec(_spec)
sys.modules["audit_release"] = audit
_spec.loader.exec_module(audit)


class SparkleLayoutTests(unittest.TestCase):
    def _framework(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        framework = Path(temporary.name) / "Sparkle.framework"
        framework.mkdir()
        manifest = audit.approved_sparkle_manifest()
        for relative, entry in sorted(manifest.items(), key=lambda item: len(Path(item[0]).parts)):
            path = framework / relative
            if entry.kind == "dir":
                path.mkdir(parents=True, exist_ok=True)
            elif entry.kind == "file":
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"")
            elif entry.kind == "symlink":
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(entry.target)
        return temporary, framework

    def test_pinned_layout_is_accepted_without_signatures(self) -> None:
        temporary, framework = self._framework()
        self.addCleanup(temporary.cleanup)
        count, _ = audit.validate_sparkle_framework(framework)
        self.assertGreater(count, 0)
    def test_xcode_header_pruning_is_accepted(self) -> None:
        temporary, framework = self._framework()
        self.addCleanup(temporary.cleanup)
        for relative in tuple(audit.approved_sparkle_manifest()):
            if audit.is_optional_sparkle_path(relative):
                path = framework / relative
                if path.is_symlink() or path.is_file():
                    path.unlink()
                elif path.is_dir():
                    import shutil

                    shutil.rmtree(path)
        audit.validate_sparkle_framework(framework)

    def test_lookalike_path_is_rejected(self) -> None:
        temporary, framework = self._framework()
        self.addCleanup(temporary.cleanup)
        (framework / "Versions/B/Sparkle.framework.evil").write_bytes(b"x")
        with self.assertRaises(audit.AuditFailure):
            audit.validate_sparkle_framework(framework)

    def test_traversal_symlink_is_rejected(self) -> None:
        temporary, framework = self._framework()
        self.addCleanup(temporary.cleanup)
        (framework / "Versions/Current").unlink()
        (framework / "Versions/Current").symlink_to("../B")
        with self.assertRaises(audit.AuditFailure):
            audit.validate_sparkle_framework(framework)

    def test_extra_nested_executable_is_rejected(self) -> None:
        temporary, framework = self._framework()
        self.addCleanup(temporary.cleanup)
        injected = framework / "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Injected"
        injected.write_bytes(b"not-a-code-object")
        with self.assertRaises(audit.AuditFailure):
            audit.validate_sparkle_framework(framework)
    def test_archive_pin_fails_closed_before_member_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / audit.SPARKLE_ARCHIVE_NAME
            archive.write_bytes(b"not-the-pinned-archive")
            with self.assertRaises(audit.AuditFailure):
                audit.locate_sparkle_archive(Path(directory))


class ReleasePolicyTests(unittest.TestCase):
    def test_entitlements_are_exact(self) -> None:
        audit.validate_entitlements(dict(audit.EXPECTED_HOST_ENTITLEMENTS))
        with self.assertRaises(audit.AuditFailure):
            audit.validate_entitlements({})
        with self.assertRaises(audit.AuditFailure):
            audit.validate_entitlements({"com.apple.security.cs.disable-library-validation": 1})
        with self.assertRaises(audit.AuditFailure):
            audit.validate_entitlements(
                {
                    **audit.EXPECTED_HOST_ENTITLEMENTS,
                    "com.apple.security.get-task-allow": True,
                }
            )

    def test_version_and_build_fail_closed(self) -> None:
        self.assertEqual(audit.validate_version("0.1.3", "4"), ("0.1.3", "4"))
        for version, build in (("v0.1.3", "4"), ("0.1.3/evil", "4"), ("0.1.3", "4/evil")):
            with self.assertRaises(audit.AuditFailure):
                audit.validate_version(version, build)

    def test_source_provenance_fail_closed(self) -> None:
        commit, source_hash = audit.validate_source_provenance(
            "A" * 40,
            "sha256:" + "b" * 64,
        )
        self.assertEqual(commit, "a" * 40)
        self.assertEqual(source_hash, "sha256:" + "b" * 64)
        for commit, source_hash in (
            (None, None),
            ("deadbeef", None),
            ("A" * 40, "sha256:" + "G" * 64),
        ):
            with self.assertRaises(audit.AuditFailure):
                audit.validate_source_provenance(commit, source_hash)

    def test_empty_optional_source_hash_uses_commit_reference(self) -> None:
        args = audit.parse_args(["--app", "/tmp/Token Jar.app", "--source-hash", ""])
        self.assertEqual(audit.validate_source_provenance("a" * 40, args.source_hash), ("a" * 40, None))

    def test_package_lock_rejects_unpinned_revision_and_extra_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "Package.resolved"
            lock.write_text(json.dumps({"pins": [audit.SPARKLE_PACKAGE_PIN]}))
            audit.validate_sparkle_package_pin(lock)
            wrong = json.loads(lock.read_text())
            wrong["pins"][0]["state"]["revision"] = "0" * 40
            lock.write_text(json.dumps(wrong))
            with self.assertRaises(audit.AuditFailure):
                audit.validate_sparkle_package_pin(lock)
            lock.write_text(json.dumps({"pins": [audit.SPARKLE_PACKAGE_PIN, audit.SPARKLE_PACKAGE_PIN]}))
            with self.assertRaises(audit.AuditFailure):
                audit.validate_sparkle_package_pin(lock)

    def test_key_feed_and_release_notes_policy_fail_closed(self) -> None:
        audit._validate_appcast_metadata(
            {
                "CFBundleIdentifier": "com.tokentank.TokenTank",
                "LSUIElement": True,
                "SUFeedURL": audit.SPARKLE_FEED_URL,
                "SUPublicEDKey": audit.SPARKLE_PUBLIC_KEY,
                "SUShowReleaseNotes": False,
                "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True,
                "SUAutomaticallyUpdate": False,
                "SUAllowsAutomaticUpdates": False,
                "SUEnableSystemProfiling": False,
                "SUSignedFeedFailureExpirationInterval": 0,
            }
        )
        for field, value in (
            ("CFBundleIdentifier", "com.example.Unreviewed"),
            ("LSUIElement", False),
            ("SUFeedURL", "https://example.invalid/appcast.xml"),
            ("SUPublicEDKey", "not-the-approved-key"),
            ("SUShowReleaseNotes", True),
            ("SURequireSignedFeed", False),
            ("SUVerifyUpdateBeforeExtraction", False),
            ("SUAutomaticallyUpdate", True),
            ("SUAllowsAutomaticUpdates", True),
            ("SUEnableSystemProfiling", True),
            ("SUSignedFeedFailureExpirationInterval", 60),
            ("SUEnableInstallerLauncherService", True),
            ("SUEnableDownloaderService", False),
            ("SUEnableInstallerConnectionService", True),
            ("SUEnableInstallerStatusService", True),
            ("SUPublicDSAKey", "unapproved"),
            ("SUPublicDSAKeyFile", "unapproved.pem"),
        ):
            metadata = {
                "CFBundleIdentifier": "com.tokentank.TokenTank",
                "LSUIElement": True,
                "SUFeedURL": audit.SPARKLE_FEED_URL,
                "SUPublicEDKey": audit.SPARKLE_PUBLIC_KEY,
                "SUShowReleaseNotes": False,
                "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True,
                "SUAutomaticallyUpdate": False,
                "SUAllowsAutomaticUpdates": False,
                "SUEnableSystemProfiling": False,
                "SUSignedFeedFailureExpirationInterval": 0,
            }
            metadata[field] = value
            with self.assertRaises(audit.AuditFailure):
                audit._validate_appcast_metadata(metadata)

    def test_browser_api_markers_do_not_match_ordinary_source_fields(self) -> None:
        self.assertIsNone(audit.FORBIDDEN_EXTERNAL_REFERENCE.search("sourceFields"))
        self.assertIsNone(audit.FORBIDDEN_EXTERNAL_REFERENCE.search("never imports browser cookies"))
        for marker in ("WebKit.framework", "WKWebView", "libcef.dylib", "cef_initialize", "Squirrel"):
            with self.subTest(marker=marker):
                self.assertIsNotNone(audit.FORBIDDEN_EXTERNAL_REFERENCE.search(marker))


if __name__ == "__main__":
    raise SystemExit(unittest.main())
