#!/usr/bin/env python3
"""Fail-closed audit for Token Jar release app bundles.

The ordinary CI invocation audits an unsigned Release product.  A packaging
invocation uses ``--mode signed`` after the ad-hoc signatures have been made.
The checker intentionally knows only the Sparkle 2.9.6 framework layout shipped
by this project; every other framework, helper, browser, and updater payload is
rejected.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, Mapping, Sequence


SPARKLE_VERSION = "2.9.6"
SPARKLE_ARCHIVE_NAME = f"Sparkle-{SPARKLE_VERSION}.tar.xz"
SPARKLE_ARCHIVE_SHA256 = "52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
SPARKLE_PACKAGE_REVISION = "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
SPARKLE_PACKAGE_PIN = {
    "identity": "sparkle",
    "kind": "remoteSourceControl",
    "location": "https://github.com/sparkle-project/Sparkle",
    "state": {"revision": SPARKLE_PACKAGE_REVISION, "version": SPARKLE_VERSION},
}
SPARKLE_ACCOUNT = "token-jar-updates"
SPARKLE_PUBLIC_KEY = "y7ka2lcx9UE9OwNlmdZzgeaU0a6l9IyqWIQ4KqFFFvM="
SPARKLE_FEED_URL = "https://raw.githubusercontent.com/nahwan-kim/token-jar/main/appcast.xml"
RELEASE_REPOSITORY = "https://github.com/nahwan-kim/token-jar"

# This is the one approved exception.  Keep this dictionary exact: adding a
# second key is a signing-policy change, not a packaging tweak.
EXPECTED_HOST_ENTITLEMENTS = {
    "com.apple.security.cs.disable-library-validation": True,
}

PRIVACY_TYPES = [
    {
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
    }
]

# Names are copied from the Sparkle 2.9.6 release framework in the pinned
# archive.  The tarball is also accepted as a runtime manifest source (see
# ``load_sparkle_manifest``), which lets CI and packaging share one verifier.
SPARKLE_PUBLIC_HEADERS = (
    "SPUAppcastSigningValidationStatus.h",
    "SPUDownloadData.h",
    "SPUStandardUpdaterController.h",
    "SPUStandardUserDriver.h",
    "SPUStandardUserDriverDelegate.h",
    "SPUUpdateCheck.h",
    "SPUUpdatePermissionRequest.h",
    "SPUUpdater.h",
    "SPUUpdaterDelegate.h",
    "SPUUpdaterSettings.h",
    "SPUUserDriver.h",
    "SPUUserUpdateState.h",
    "SUAppcast.h",
    "SUAppcastItem.h",
    "SUErrors.h",
    "SUExport.h",
    "SUStandardVersionComparator.h",
    "SUUpdatePermissionResponse.h",
    "SUUpdater.h",
    "SUUpdaterDelegate.h",
    "SUVersionComparisonProtocol.h",
    "SUVersionDisplayProtocol.h",
    "Sparkle.h",
)
SPARKLE_PRIVATE_HEADERS = (
    "SPUAppcastItemStateResolver.h",
    "SPUGentleUserDriverReminders.h",
    "SPUInstallationType.h",
    "SPUStandardUserDriver+Private.h",
    "SPUUserAgent+Private.h",
    "SUAppcastItem+Private.h",
    "SUInstallerLauncher+Private.h",
)
SPARKLE_LOCALES = (
    "Base",
    "ar",
    "ca",
    "cs",
    "da",
    "de",
    "el",
    "es",
    "fa",
    "fi",
    "fr",
    "he",
    "hr",
    "hu",
    "is",
    "it",
    "ja",
    "ko",
    "nb",
    "nl",
    "nn",
    "pl",
    "pt-BR",
    "pt-PT",
    "ro",
    "ru",
    "sk",
    "sl",
    "sv",
    "th",
    "tr",
    "uk",
    "vi",
    "zh_CN",
    "zh_HK",
    "zh_TW",
)

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}

TEST_MARKERS = (
    b"ui-test-detail",
    b"ui-test.",
    b"Token Jar UI Test Detail",
    b"UITEST",
    b"TokenTankUITests",
    b"___profc_",
    b"___profd_",
    b"__llvm_profile",
    b"-profile-generate",
)
SECRET_PATTERNS = (
    re.compile(rb"sk-[A-Za-z0-9_-]{20,}"),
    re.compile(rb"sk-ant-[A-Za-z0-9_-]{20,}"),
    re.compile(rb"xai-[A-Za-z0-9_-]{20,}"),
    re.compile(rb"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
)
ABSOLUTE_PATH_PATTERNS = (
    re.compile(rb"/Users/[^/\x00]+/"),
    re.compile(rb"/home/[^/\x00]+/"),
    re.compile(rb"/private/var/folders/[^/\x00]+/"),
)
FILE_TIMESTAMP_IMPORT = re.compile(
    r"(?:^|\s)_?(?:stat|fstat|fstatat|lstat|getattrlist|getattrlistbulk|"
    r"fgetattrlist|getattrlistat)(?:$|\s)",
    re.MULTILINE,
)
# Browser/WebKit is approved only for the vendor Sparkle payload.  Sparkle
# symbols and its framework dependency are expected in the host executable.
FORBIDDEN_EXTERNAL_REFERENCE = re.compile(
    r"WebKit|SafariServices|Chromium|Electron|ChromiumEmbeddedFramework|"
    r"libcef[./]|cef_initialize|cef_browser_host|Squirrel|WKWebView|UpdateAgent|UpdateKit",
    re.IGNORECASE,
)
FORBIDDEN_VENDOR_REFERENCE = re.compile(
    r"SafariServices|Chromium|Electron|ChromiumEmbeddedFramework|"
    r"libcef[./]|cef_initialize|cef_browser_host|Squirrel|UpdateAgent|UpdateKit",
    re.IGNORECASE,
)


class AuditFailure(RuntimeError):
    """A user-actionable release audit failure."""


@dataclass(frozen=True)
class ManifestEntry:
    kind: str  # dir, file, or symlink
    target: str | None = None


# Paths that codesign creates.  They may be absent in an unsigned CI product,
# but are mandatory in signed package mode.
SIGNATURE_PATHS = frozenset(
    {
        "Versions/B/_CodeSignature",
        "Versions/B/_CodeSignature/CodeResources",
        "Versions/B/Updater.app/Contents/_CodeSignature",
        "Versions/B/Updater.app/Contents/_CodeSignature/CodeResources",
        "Versions/B/XPCServices/Downloader.xpc/Contents/_CodeSignature",
        "Versions/B/XPCServices/Downloader.xpc/Contents/_CodeSignature/CodeResources",
        "Versions/B/XPCServices/Installer.xpc/Contents/_CodeSignature",
        "Versions/B/XPCServices/Installer.xpc/Contents/_CodeSignature/CodeResources",
    }
)
def is_optional_sparkle_path(path: str) -> bool:
    return (
        path in {"Headers", "Modules", "PrivateHeaders", "Versions/B/Headers", "Versions/B/Modules", "Versions/B/PrivateHeaders"}
        or path.startswith("Versions/B/Headers/")
        or path.startswith("Versions/B/Modules/")
        or path.startswith("Versions/B/PrivateHeaders/")
    )


def _add_manifest_entry(entries: dict[str, ManifestEntry], path: str, kind: str, target: str | None = None) -> None:
    if path in entries and entries[path] != ManifestEntry(kind, target):
        raise AuditFailure(f"conflicting Sparkle manifest entry: {path}")
    entries[path] = ManifestEntry(kind, target)


def approved_sparkle_manifest() -> dict[str, ManifestEntry]:
    """Return the immutable Sparkle 2.9.6 layout used when no tar is supplied."""
    entries: dict[str, ManifestEntry] = {}
    for path, target in (
        ("Autoupdate", "Versions/Current/Autoupdate"),
        ("Headers", "Versions/Current/Headers"),
        ("Modules", "Versions/Current/Modules"),
        ("PrivateHeaders", "Versions/Current/PrivateHeaders"),
        ("Resources", "Versions/Current/Resources"),
        ("Sparkle", "Versions/Current/Sparkle"),
        ("Updater.app", "Versions/Current/Updater.app"),
        ("XPCServices", "Versions/Current/XPCServices"),
        ("Versions/Current", "B"),
    ):
        _add_manifest_entry(entries, path, "symlink", target)
    for path in (
        "Versions",
        "Versions/B",
        "Versions/B/Headers",
        "Versions/B/Modules",
        "Versions/B/PrivateHeaders",
        "Versions/B/Resources",
        "Versions/B/Resources/SUUpdatePermissionPrompt.nib",
        "Versions/B/Updater.app",
        "Versions/B/Updater.app/Contents",
        "Versions/B/Updater.app/Contents/MacOS",
        "Versions/B/Updater.app/Contents/Resources",
        "Versions/B/XPCServices",
        "Versions/B/XPCServices/Downloader.xpc",
        "Versions/B/XPCServices/Downloader.xpc/Contents",
        "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS",
        "Versions/B/XPCServices/Installer.xpc",
        "Versions/B/XPCServices/Installer.xpc/Contents",
        "Versions/B/XPCServices/Installer.xpc/Contents/MacOS",
    ):
        _add_manifest_entry(entries, path, "dir")
    for path in (
        "Versions/B/Autoupdate",
        "Versions/B/Sparkle",
        "Versions/B/Modules/module.modulemap",
        "Versions/B/Modules/module.private.modulemap",
        "Versions/B/Resources/Info.plist",
        "Versions/B/Resources/ReleaseNotesColorStyle.css",
        "Versions/B/Resources/SUStatus.nib",
        "Versions/B/Resources/SUUpdateAlert.nib",
        "Versions/B/Resources/SUUpdatePermissionPrompt.nib/keyedobjects-101300.nib",
        "Versions/B/Resources/SUUpdatePermissionPrompt.nib/keyedobjects-110000.nib",
        "Versions/B/Updater.app/Contents/Info.plist",
        "Versions/B/Updater.app/Contents/MacOS/Updater",
        "Versions/B/Updater.app/Contents/PkgInfo",
        "Versions/B/Updater.app/Contents/Resources/SUStatus.nib",
        "Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist",
        "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        "Versions/B/XPCServices/Installer.xpc/Contents/Info.plist",
        "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    ):
        _add_manifest_entry(entries, path, "file")
    for header in SPARKLE_PUBLIC_HEADERS:
        _add_manifest_entry(entries, f"Versions/B/Headers/{header}", "file")
    for header in SPARKLE_PRIVATE_HEADERS:
        _add_manifest_entry(entries, f"Versions/B/PrivateHeaders/{header}", "file")
    for locale in SPARKLE_LOCALES:
        _add_manifest_entry(entries, f"Versions/B/Resources/{locale}.lproj", "dir")
        _add_manifest_entry(entries, f"Versions/B/Resources/{locale}.lproj/Sparkle.strings", "file")
    for path in SIGNATURE_PATHS:
        _add_manifest_entry(entries, path, "dir" if path.endswith("_CodeSignature") else "file")
    return entries


def _normalise_member_name(name: str) -> str:
    if not name or "\x00" in name:
        raise AuditFailure("Sparkle archive contains an invalid member name")
    if name.startswith("/"):
        raise AuditFailure(f"Sparkle archive contains an absolute member: {name!r}")
    raw = name[2:] if name.startswith("./") else name
    raw_parts = raw.split("/")
    if not raw_parts or any(part in ("", ".", "..") for part in raw_parts):
        raise AuditFailure(f"Sparkle archive contains a traversal member: {name!r}")
    path = PurePosixPath(raw)
    if path.is_absolute():
        raise AuditFailure(f"Sparkle archive contains an absolute member: {name!r}")
    return str(path)


def _validate_archive_members(archive: Path) -> list[tarfile.TarInfo]:
    try:
        with tarfile.open(archive, mode="r:xz") as stream:
            members = stream.getmembers()
    except (OSError, tarfile.TarError) as error:
        raise AuditFailure(f"cannot read pinned Sparkle archive: {archive}") from error
    seen: set[str] = set()
    for member in members:
        normalised = _normalise_member_name(member.name)
        if normalised in seen:
            raise AuditFailure(f"Sparkle archive contains duplicate member: {normalised}")
        seen.add(normalised)
        if member.issym() or member.islnk():
            target = member.linkname
            target_parts = target.split("/")
            if target.startswith("/") or not target_parts or any(
                part in ("", ".", "..") for part in target_parts
            ):
                raise AuditFailure(f"Sparkle archive contains an unsafe link: {normalised}")
    required = {
        "Sparkle.framework/Versions/B/Sparkle",
        "Sparkle.framework/Versions/B/Autoupdate",
        "bin/generate_appcast",
        "bin/generate_keys",
        "bin/sign_update",
    }
    missing = sorted(required - seen)
    if missing:
        raise AuditFailure(f"pinned Sparkle archive is missing required members: {missing}")
    framework_members = {name for name in seen if name == "Sparkle.framework" or name.startswith("Sparkle.framework/")}
    if not framework_members:
        raise AuditFailure("pinned Sparkle archive has no Sparkle.framework payload")
    return members


def locate_sparkle_archive(distribution: Path) -> Path:
    distribution = distribution.expanduser()
    if distribution.is_file():
        archive = distribution
    elif distribution.is_dir():
        archive = distribution / SPARKLE_ARCHIVE_NAME
    else:
        raise AuditFailure(f"Sparkle distribution path does not exist: {distribution}")
    if archive.name != SPARKLE_ARCHIVE_NAME or not archive.is_file() or archive.is_symlink():
        raise AuditFailure(f"Sparkle distribution must contain a regular {SPARKLE_ARCHIVE_NAME}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != SPARKLE_ARCHIVE_SHA256:
        raise AuditFailure(
            f"Sparkle archive SHA-256 mismatch: expected {SPARKLE_ARCHIVE_SHA256}, got {digest}"
        )
    _validate_archive_members(archive)
    return archive


def load_sparkle_manifest(distribution: Path | None) -> dict[str, ManifestEntry]:
    """Load a checked archive layout, or the pinned in-source layout for CI."""
    if distribution is None:
        return approved_sparkle_manifest()
    archive = locate_sparkle_archive(distribution)
    entries: dict[str, ManifestEntry] = {}
    with tarfile.open(archive, mode="r:xz") as stream:
        for member in stream.getmembers():
            name = _normalise_member_name(member.name)
            if name == "Sparkle.framework":
                continue
            if not name.startswith("Sparkle.framework/"):
                continue
            relative = name[len("Sparkle.framework/") :]
            if member.issym() or member.islnk():
                _add_manifest_entry(entries, relative, "symlink", member.linkname)
            elif member.isdir():
                _add_manifest_entry(entries, relative, "dir")
            elif member.isfile():
                _add_manifest_entry(entries, relative, "file")
            else:
                raise AuditFailure(f"unsupported Sparkle archive member: {name}")
    # Tar releases may omit directory records.  Derive only the parent
    # directories of checked file/link paths; this also mirrors Xcode's
    # header-pruning step without inventing payload files.
    for relative in tuple(entries):
        parts = PurePosixPath(relative).parts
        for index in range(1, len(parts)):
            parent = str(PurePosixPath(*parts[:index]))
            if parent not in entries:
                _add_manifest_entry(entries, parent, "dir")
    # The checked archive itself remains the authority, but mandatory entries
    # prevent an accidental tiny fixture from widening the approved footprint.
    baseline = approved_sparkle_manifest()
    for path, baseline_entry in baseline.items():
        if path in SIGNATURE_PATHS or is_optional_sparkle_path(path):
            continue
        actual = entries.get(path)
        if actual != baseline_entry:
            raise AuditFailure(f"pinned Sparkle framework layout changed at {path}")
    return entries


def _lstat_kind(path: Path) -> str:
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def _iter_tree_no_follow(root: Path) -> Iterable[Path]:
    # os.walk does not recurse through symlink directories with followlinks=False;
    # retaining the link itself is important for the framework version layout.
    for directory, directories, files in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in sorted(directories + files):
            yield directory_path / name


def _assert_inside(root: Path, path: Path) -> None:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError, RuntimeError) as error:
        try:
            display = path.relative_to(root)
        except ValueError:
            display = path
        raise AuditFailure(f"bundle symlink escapes the app: {display}") from error


def validate_sparkle_framework(
    framework: Path,
    manifest: Mapping[str, ManifestEntry] | None = None,
    *,
    require_signatures: bool = False,
) -> tuple[int, set[Path]]:
    """Validate exact framework paths, symlink targets, and code object names."""
    framework = framework.expanduser()
    if not framework.is_dir() or framework.is_symlink():
        raise AuditFailure("Contents/Frameworks/Sparkle.framework must be a real directory")
    manifest = manifest or approved_sparkle_manifest()
    actual: dict[str, str] = {}
    for path in _iter_tree_no_follow(framework):
        relative = PurePosixPath(path.relative_to(framework).as_posix())
        relative_name = str(relative)
        if any(part in ("", ".", "..") for part in relative.parts):
            raise AuditFailure(f"invalid Sparkle framework path: {relative_name}")
        _assert_inside(framework, path)
        kind = _lstat_kind(path)
        if kind == "symlink":
            target = os.readlink(path)
            actual[relative_name] = kind
            expected = manifest.get(relative_name)
            if expected is None or expected.kind != "symlink" or expected.target != target:
                raise AuditFailure(f"unapproved Sparkle symlink: {relative_name} -> {target}")
        else:
            actual[relative_name] = kind
            expected = manifest.get(relative_name)
            if expected is None:
                raise AuditFailure(f"unapproved Sparkle framework path: {relative_name}")
            if expected.kind != kind:
                raise AuditFailure(
                    f"Sparkle framework type mismatch at {relative_name}: expected {expected.kind}, got {kind}"
                )
        if kind == "other":
            raise AuditFailure(f"unsupported Sparkle framework object: {relative_name}")
    for relative_name, expected in manifest.items():
        if relative_name in actual:
            continue
        if (relative_name in SIGNATURE_PATHS and not require_signatures) or is_optional_sparkle_path(
            relative_name
        ):
            continue
        raise AuditFailure(f"Sparkle framework is missing approved path: {relative_name}")
    code_objects = {
        framework / "Versions/B/Autoupdate",
        framework / "Versions/B/Sparkle",
        framework / "Versions/B/Updater.app",
        framework / "Versions/B/Updater.app/Contents/MacOS/Updater",
        framework / "Versions/B/XPCServices/Downloader.xpc",
        framework / "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        framework / "Versions/B/XPCServices/Installer.xpc",
        framework / "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    }
    return len(actual), code_objects
def validate_sparkle_framework_metadata(framework: Path) -> None:
    info_path = framework / "Versions/B/Resources/Info.plist"
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise AuditFailure(f"cannot read Sparkle framework Info.plist: {info_path}") from error
    if not isinstance(info, dict):
        raise AuditFailure("Sparkle framework Info.plist root must be a dictionary")
    if info.get("CFBundleShortVersionString") != SPARKLE_VERSION:
        raise AuditFailure("embedded Sparkle framework version is not 2.9.6")
    if info.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle":
        raise AuditFailure("embedded Sparkle framework identifier is not Sparkle")


def read_info_plist(app: Path) -> dict[str, object]:
    info_path = app / "Contents/Info.plist"
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise AuditFailure(f"cannot read app Info.plist: {info_path}") from error
    if not isinstance(info, dict):
        raise AuditFailure("app Info.plist root must be a dictionary")
    return info


def validate_version(version: object, build: object) -> tuple[str, str]:
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise AuditFailure(f"invalid CFBundleShortVersionString: {version!r}")
    if not isinstance(build, str) or not re.fullmatch(r"[0-9]+", build):
        raise AuditFailure(f"invalid CFBundleVersion: {build!r}")
    return version, build


def validate_source_provenance(source_commit: str | None, source_hash: str | None) -> tuple[str, str | None]:
    if not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", source_commit):
        raise AuditFailure("GITHUB_SHA/source commit is missing or malformed")
    if source_hash:
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", source_hash):
            raise AuditFailure("TOKENTANK_SOURCE_HASH/source hash is malformed")
        return source_commit.lower(), source_hash
    return source_commit.lower(), None


def validate_entitlements(entitlements: Mapping[str, object]) -> None:
    try:
        actual = dict(entitlements)
    except (TypeError, ValueError) as error:
        raise AuditFailure("host entitlements must be a dictionary") from error
    if (
        set(actual) != set(EXPECTED_HOST_ENTITLEMENTS)
        or type(actual.get("com.apple.security.cs.disable-library-validation")) is not bool
        or actual.get("com.apple.security.cs.disable-library-validation") is not True
    ):
        raise AuditFailure(
            "host entitlements must be exactly "
            "{'com.apple.security.cs.disable-library-validation': True}"
        )


def _run(command: Sequence[str], *, allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        raise AuditFailure(f"required tool is unavailable: {command[0]}") from error
    if result.returncode and not allow_failure:
        detail = (result.stderr or result.stdout).strip()
        raise AuditFailure(f"command failed ({' '.join(command)}): {detail}")
    return result


def _codesign_entitlements(path: Path) -> dict[str, object]:
    result = _run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)])
    if not result.stdout.strip():
        return {}
    try:
        value = plistlib.loads(result.stdout.encode())
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise AuditFailure(f"could not decode entitlements for {path}") from error
    if not isinstance(value, dict):
        raise AuditFailure(f"entitlements for {path} are not a dictionary")
    return value


def _verify_signed_code(path: Path, *, host: bool = False) -> None:
    _run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(path)])
    details = _run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    combined = f"{details.stdout}\n{details.stderr}"
    flags_match = re.search(r"\bflags=0x([0-9A-Fa-f]+)\(([^)]*)\)", combined)
    if (
        flags_match is None
        or not (int(flags_match.group(1), 16) & 0x10000)
        or "runtime" not in {flag.strip().lower() for flag in flags_match.group(2).split(",")}
    ):
        raise AuditFailure(f"Hardened Runtime flag is missing from {path}")
    if "signature=adhoc" not in combined.lower():
        # Developer ID is a valid future channel, but this release's signed
        # mode is intentionally the approved ad-hoc channel.
        raise AuditFailure(f"signed package is not ad-hoc signed: {path}")
    entitlements = _codesign_entitlements(path)
    if host:
        validate_entitlements(entitlements)
    elif entitlements:
        raise AuditFailure(f"nested Sparkle code has unexpected entitlements: {path}")
def _is_sparkle_path(path: Path, framework: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(framework.resolve(strict=True))
        return True
    except (OSError, ValueError, RuntimeError):
        return False
def _scan_macho(path: Path, app: Path, framework: Path) -> None:
    dependencies = _run(["/usr/bin/otool", "-L", str(path)]).stdout
    symbols = _run(["/usr/bin/strings", "-a", str(path)]).stdout
    imports = _run(["/usr/bin/nm", "-u", str(path)]).stdout
    in_sparkle = _is_sparkle_path(path, framework)
    if FILE_TIMESTAMP_IMPORT.search(imports) and not in_sparkle:
        raise AuditFailure(f"direct FileTimestamp API import outside Sparkle in {path.relative_to(app)}")
    references = f"{dependencies}\n{symbols}"
    if (FORBIDDEN_VENDOR_REFERENCE if in_sparkle else FORBIDDEN_EXTERNAL_REFERENCE).search(references):
        raise AuditFailure(f"forbidden browser/updater reference in {path.relative_to(app)}")


def _validate_appcast_metadata(info: Mapping[str, object]) -> None:
    if info.get("CFBundleIdentifier") != "com.tokentank.TokenTank":
        raise AuditFailure("release bundle identifier must be com.tokentank.TokenTank")
    if info.get("LSUIElement") is not True:
        raise AuditFailure("release app must remain menu-bar-only")
    if info.get("SUFeedURL") != SPARKLE_FEED_URL:
        raise AuditFailure(f"SUFeedURL must be {SPARKLE_FEED_URL}")
    if info.get("SUPublicEDKey") != SPARKLE_PUBLIC_KEY:
        raise AuditFailure("SUPublicEDKey does not match the approved Sparkle key")
    if info.get("SUShowReleaseNotes") is not False:
        raise AuditFailure("SUShowReleaseNotes must be false for this app")
    if info.get("SURequireSignedFeed") is not True:
        raise AuditFailure("SURequireSignedFeed must be true")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise AuditFailure("SUVerifyUpdateBeforeExtraction must be true")
    if info.get("SUAutomaticallyUpdate") is not False:
        raise AuditFailure("SUAutomaticallyUpdate must be false")
    if info.get("SUAllowsAutomaticUpdates") is not False:
        raise AuditFailure("SUAllowsAutomaticUpdates must be false")
    if info.get("SUEnableSystemProfiling") is not False:
        raise AuditFailure("SUEnableSystemProfiling must be false")
    expiration = info.get("SUSignedFeedFailureExpirationInterval")
    if type(expiration) is not int or expiration != 0:
        raise AuditFailure("SUSignedFeedFailureExpirationInterval must be integer 0")
    for key in (
        "SUEnableInstallerLauncherService", "SUEnableDownloaderService",
        "SUEnableInstallerConnectionService", "SUEnableInstallerStatusService",
        "SUPublicDSAKey", "SUPublicDSAKeyFile",
    ):
        if key in info:
            raise AuditFailure(f"unapproved updater configuration: {key}")


def validate_sparkle_package_pin(lock_path: Path) -> None:
    try:
        lock = json.loads(lock_path.read_bytes())
    except (OSError, ValueError) as error:
        raise AuditFailure(f"cannot read Sparkle package lock: {lock_path}") from error
    if not isinstance(lock, dict) or lock.get("pins") != [SPARKLE_PACKAGE_PIN]:
        raise AuditFailure("Package.resolved must pin only the approved Sparkle 2.9.6 revision")


def scan_app(
    app: Path,
    *,
    mode: str = "unsigned",
    source_commit: str | None = None,
    source_hash: str | None = None,
    entitlements_file: Path | None = None,
    sparkle_distribution: Path | None = None,
) -> dict[str, object]:
    validate_sparkle_package_pin(
        Path(__file__).resolve().parent.parent
        / "TokenTank.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    )
    app = app.expanduser()
    if app.is_symlink():
        raise AuditFailure("app bundle must not be a symlink")
    app = app.resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise AuditFailure(f"app bundle is missing or not a .app directory: {app}")
    contents = app / "Contents"
    if not contents.is_dir():
        raise AuditFailure("app bundle is missing Contents")
    app_root = app
    info = read_info_plist(app)
    version, build = validate_version(info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not re.fullmatch(r"[^/]+", executable):
        raise AuditFailure("CFBundleExecutable is missing or unsafe")
    binary = contents / "MacOS" / executable
    if not binary.is_file() or binary.is_symlink():
        raise AuditFailure(f"main executable is missing: {binary.relative_to(app)}")
    _validate_appcast_metadata(info)
    if info.get("LSUIElement") is not True:
        raise AuditFailure("LSUIElement must be true for the menu-bar-only app")

    if entitlements_file is not None:
        try:
            with entitlements_file.open("rb") as stream:
                source_entitlements = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException, ValueError) as error:
            raise AuditFailure(f"cannot read source entitlements: {entitlements_file}") from error
        if not isinstance(source_entitlements, dict):
            raise AuditFailure("source entitlements root must be a dictionary")
        validate_entitlements(source_entitlements)

    privacy_path = contents / "Resources" / "PrivacyInfo.xcprivacy"
    try:
        privacy = plistlib.loads(privacy_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise AuditFailure(f"cannot read exported privacy manifest: {privacy_path}") from error
    if privacy.get("NSPrivacyAccessedAPITypes") != PRIVACY_TYPES:
        raise AuditFailure("exported privacy required-reason declarations changed")

    frameworks_dir = contents / "Frameworks"
    if not frameworks_dir.is_dir():
        raise AuditFailure("Contents/Frameworks is missing")
    framework_entries = sorted(path.name for path in frameworks_dir.iterdir())
    if framework_entries != ["Sparkle.framework"]:
        raise AuditFailure(f"only Sparkle.framework may be embedded: {framework_entries}")
    framework = frameworks_dir / "Sparkle.framework"
    manifest = load_sparkle_manifest(sparkle_distribution)
    sparkle_file_count, sparkle_code_objects = validate_sparkle_framework(
        framework,
        manifest,
        require_signatures=mode == "signed",
    )
    validate_sparkle_framework_metadata(framework)
    sparkle_macho_paths = {
        path for path in sparkle_code_objects if _lstat_kind(path) == "file"
    }

    blocked_component = re.compile(
        r"WebKit|SafariServices|Safari|Browser|Chromium|Electron|CEF|Sparkle|"
        r"Squirrel|Updater|Update|Helpers|XPCServices|LoginItems|PrivilegedHelperTools",
        re.IGNORECASE,
    )
    macho_files: list[Path] = []
    bundle_file_count = 0
    for path in _iter_tree_no_follow(app):
        relative = path.relative_to(app)
        if path == framework or _is_sparkle_path(path, framework):
            pass
        else:
            if blocked_component.fullmatch(path.name) or blocked_component.fullmatch(path.stem):
                raise AuditFailure(f"forbidden browser, updater, or helper payload: {relative}")
            if path.suffix.lower() in {".framework", ".xpc", ".appex", ".dsym"}:
                raise AuditFailure(f"unapproved nested bundle payload: {relative}")
        _assert_inside(app_root, path)
        kind = _lstat_kind(path)
        if kind != "file":
            continue
        bundle_file_count += 1
        payload = path.read_bytes()
        leaked_markers = [marker.decode("utf-8", "replace") for marker in TEST_MARKERS if marker in payload]
        if leaked_markers:
            raise AuditFailure(f"test or profiling marker leaked into {relative}: {leaked_markers}")
        if any(pattern.search(payload) for pattern in ABSOLUTE_PATH_PATTERNS):
            raise AuditFailure(f"absolute build or user path leaked into {relative}")
        if any(pattern.search(payload) for pattern in SECRET_PATTERNS):
            raise AuditFailure(f"credential-shaped value leaked into {relative}")
        if payload[:4] in MACHO_MAGICS:
            macho_files.append(path)

    if binary not in macho_files:
        raise AuditFailure("main executable is missing or is not Mach-O")
    allowed_macho_files = {binary} | sparkle_macho_paths
    if set(macho_files) != allowed_macho_files:
        extra = sorted(str(path.relative_to(app)) for path in set(macho_files) - allowed_macho_files)
        missing = sorted(str(path.relative_to(app)) for path in allowed_macho_files - set(macho_files))
        raise AuditFailure(f"unexpected executable inventory: extra={extra}, missing={missing}")
    architectures = set(_run(["/usr/bin/lipo", "-archs", str(binary)]).stdout.split())
    if architectures != {"arm64", "x86_64"}:
        raise AuditFailure(f"Release binary is not universal: {sorted(architectures)}")
    for macho in macho_files:
        _scan_macho(macho, app, framework)

    source_commit, source_hash = validate_source_provenance(
        source_commit if source_commit is not None else os.environ.get("GITHUB_SHA"),
        source_hash if source_hash is not None else os.environ.get("TOKENTANK_SOURCE_HASH"),
    )

    if mode == "signed":
        _verify_signed_code(app, host=True)
        _verify_signed_code(framework)
        for code_object in sorted(sparkle_code_objects, key=lambda item: len(item.parts), reverse=True):
            # Binaries and their containing bundles are both checked.  This is
            # intentionally redundant: it prevents a valid outer signature
            # from hiding an unsigned nested executable.
            if code_object.is_file() and code_object.name in {"Updater", "Downloader", "Installer"}:
                _verify_signed_code(code_object)
            elif code_object.is_dir() and code_object.name in {"Updater.app", "Downloader.xpc", "Installer.xpc"}:
                _verify_signed_code(code_object)
            elif code_object.is_file():
                _verify_signed_code(code_object)

    receipt: dict[str, object] = {
        "schema": "tokentank.release-receipt.v2",
        "sourceCommit": source_commit,
        "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "binaryBytes": binary.stat().st_size,
        "architectures": sorted(architectures),
        "machOFilesScanned": len(macho_files),
        "bundleFilesScanned": bundle_file_count,
        "sparkleFrameworkFilesScanned": sparkle_file_count,
        "sparkleVersion": SPARKLE_VERSION,
        "sparkleToolingArchiveSHA256": SPARKLE_ARCHIVE_SHA256,
        "sparklePackageRevision": SPARKLE_PACKAGE_REVISION,
        "sourceBuildProvenance": "requires operator build record; source hash is caller-supplied",
        "checks": {
            "architectures": "passed",
            "bundlePayload": "passed",
            "dependenciesAndSymbols": "passed",
            "entitlements": "passed",
            "privacyManifestAndImports": "passed",
            "releaseMarkerLeakage": "passed",
            "secretAndPathLeakage": "passed",
            "sourceReferenceFormat": "passed",
            "sparklePackagePin": "passed",
            "sparkleFootprint": "passed",
            "signedCode": "passed" if mode == "signed" else "not-required",
        },
    }
    if source_hash:
        receipt["sourceHash"] = source_hash
    return receipt


def _validate_archive_action(distribution: Path) -> dict[str, object]:
    archive = locate_sparkle_archive(distribution)
    manifest = load_sparkle_manifest(distribution)
    return {
        "archive": str(archive),
        "sha256": SPARKLE_ARCHIVE_SHA256,
        "frameworkPaths": len(manifest),
        "sparkleVersion": SPARKLE_VERSION,
    }


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit a Token Jar app bundle and its exact Sparkle 2.9.6 payload."
    )
    parser.add_argument("--app", type=Path, help="Token Jar.app bundle to audit")
    parser.add_argument("--mode", choices=("unsigned", "signed"), default="unsigned")
    parser.add_argument("--source-commit", help="40-hex source commit (defaults to GITHUB_SHA)")
    parser.add_argument("--source-hash", help="optional sha256:<64-hex> source hash")
    parser.add_argument(
        "--entitlements",
        dest="entitlements_file",
        type=Path,
        help="source entitlements plist; it must contain the exact approved host exception",
    )
    parser.add_argument(
        "--sparkle-distribution",
        type=Path,
        help=f"directory containing the pinned {SPARKLE_ARCHIVE_NAME}; CI defaults to the built-in manifest",
    )
    parser.add_argument("--receipt", type=Path, help="write the JSON receipt to this path")
    parser.add_argument("--summary", type=Path, help="append the receipt to a GitHub step summary")
    parser.add_argument(
        "--validate-sparkle-distribution",
        type=Path,
        metavar="PATH",
        help="validate a pinned Sparkle source distribution without auditing an app",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.validate_sparkle_distribution is not None:
            result = _validate_archive_action(args.validate_sparkle_distribution)
        else:
            if args.app is None:
                raise AuditFailure("--app is required unless --validate-sparkle-distribution is used")
            result = scan_app(
                args.app,
                mode=args.mode,
                source_commit=args.source_commit,
                source_hash=args.source_hash,
                entitlements_file=args.entitlements_file,
                sparkle_distribution=args.sparkle_distribution,
            )
        rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
        print(rendered, end="")
        if args.receipt is not None:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(rendered, encoding="utf-8")
        if args.summary is not None:
            with args.summary.open("a", encoding="utf-8") as summary:
                summary.write("### Token Jar Release receipt\n\n```json\n")
                summary.write(rendered)
                summary.write("```\n")
    except AuditFailure as error:
        print(f"audit-release.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
