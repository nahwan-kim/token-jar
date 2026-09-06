#!/bin/bash
# Build one signed, local Sparkle release artifact.  This script never uploads,
# edits a remote feed, exports a key, or modifies the input app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PYTHON="${PYTHON:-/usr/bin/python3}"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-release.py"
SPARKLE_VERSION="2.9.6"
SPARKLE_ARCHIVE_NAME="Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_ARCHIVE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
SPARKLE_ACCOUNT="token-jar-updates"
SPARKLE_PUBLIC_KEY="y7ka2lcx9UE9OwNlmdZzgeaU0a6l9IyqWIQ4KqFFFvM="
RELEASE_REPOSITORY="https://github.com/nahwan-kim/token-jar"

usage() {
    cat <<'EOF'
Usage:
  bash Scripts/package-release.sh --app PATH --output PATH.zip --sparkle-tools-dir PATH
  bash Scripts/package-release.sh PATH.app PATH.zip SPARKLE-DISTRIBUTION-DIR

The Sparkle distribution directory must contain the pinned
Sparkle-2.9.6.tar.xz archive.  The archive is checked against its SHA-256 before
any member is extracted.  The script copies LICENSE and THIRD_PARTY_NOTICES into
the staged app, signs every Sparkle code object and the host ad-hoc with
Hardened Runtime (timestamp disabled), creates a ditto ZIP, SHA256SUMS, and a
signed appcast.xml and RELEASE_RECEIPT.json beside the ZIP. The private key is read only
from the login Keychain account token-jar-updates; it is never exported or read
from standard input. Existing artifact or receipt outputs are refused.
No upload or remote-state change is performed. Dirty worktrees require a caller-
supplied TOKENTANK_SOURCE_HASH (sha256:<64hex>); the receipt labels it as an
operator reference, not a reproduced source-to-binary provenance proof.
EOF
}

fail() {
    printf 'package-release.sh: %s\n' "$1" >&2
    exit 1
}

app=""
output=""
sparkle_tools_dir=""
positionals=()
while (($#)); do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --app)
            (($# >= 2)) || fail "--app requires a path"
            [[ -z "$app" ]] || fail "--app was specified more than once"
            app="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || fail "--output requires a path"
            [[ -z "$output" ]] || fail "--output was specified more than once"
            output="$2"
            shift 2
            ;;
        --sparkle-tools-dir)
            (($# >= 2)) || fail "--sparkle-tools-dir requires a path"
            [[ -z "$sparkle_tools_dir" ]] || fail "--sparkle-tools-dir was specified more than once"
            sparkle_tools_dir="$2"
            shift 2
            ;;
        --)
            shift
            while (($#)); do
                positionals+=("$1")
                shift
            done
            ;;
        -*)
            fail "unknown option: $1 (use --help)"
            ;;
        *)
            positionals+=("$1")
            shift
            ;;
    esac
done

if ((${#positionals[@]})); then
    ((${#positionals[@]} == 3)) || fail "positional usage requires APP OUTPUT SPARKLE-DISTRIBUTION"
    [[ -z "$app" ]] || fail "do not mix --app with positional APP"
    [[ -z "$output" ]] || fail "do not mix --output with positional OUTPUT"
    [[ -z "$sparkle_tools_dir" ]] || fail "do not mix --sparkle-tools-dir with positional distribution"
    app="${positionals[0]}"
    output="${positionals[1]}"
    sparkle_tools_dir="${positionals[2]}"
fi
[[ -n "$app" && -n "$output" && -n "$sparkle_tools_dir" ]] || {
    usage >&2
    exit 2
}
[[ -x "$PYTHON" ]] || fail "Python interpreter is unavailable: $PYTHON"
[[ -f "$AUDIT_SCRIPT" ]] || fail "audit script is missing: $AUDIT_SCRIPT"
[[ -d "$app" && "$app" == *.app ]] || fail "--app must be an existing .app directory"
[[ ! -L "$app" ]] || fail "--app must not be a symlink"
[[ -d "$sparkle_tools_dir" && ! -L "$sparkle_tools_dir" ]] || fail "Sparkle distribution directory is unavailable"

app="$(cd -- "$app" && pwd -P)"
sparkle_tools_dir="$(cd -- "$sparkle_tools_dir" && pwd -P)"
output_dir="$("$PYTHON" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).parent.resolve())' "$output")"
output_name="$(basename -- "$output")"
[[ "$output_dir/" != "$app/"* ]] || fail "--output must be outside the input app"
mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
output="$output_dir/$output_name"
[[ "$output_name" == *.zip ]] || fail "--output must end in .zip"
[[ "$output_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$ ]] || fail "ZIP filename contains unsafe characters"

appcast="$output_dir/appcast.xml"
checksums="$output_dir/SHA256SUMS"
receipt="$output_dir/RELEASE_RECEIPT.json"
for existing in "$output" "$appcast" "$checksums" "$receipt"; do
    [[ ! -e "$existing" && ! -L "$existing" ]] || fail "refusing existing output: $existing"
done
[[ -f "$REPO_ROOT/LICENSE" ]] || fail "repository LICENSE is missing"
[[ -f "$REPO_ROOT/THIRD_PARTY_NOTICES" ]] || fail "repository THIRD_PARTY_NOTICES is missing"

archive="$sparkle_tools_dir/$SPARKLE_ARCHIVE_NAME"
[[ -f "$archive" && ! -L "$archive" ]] || fail "pinned archive is missing: $archive"
archive_sha256="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/cut -d ' ' -f1)"
[[ "$archive_sha256" == "$SPARKLE_ARCHIVE_SHA256" ]] || fail "pinned Sparkle archive SHA-256 mismatch"

# Validate the digest, all archive names, and link targets before extracting
# anything.  The Python checker also confirms the required tools/framework.
"$PYTHON" "$AUDIT_SCRIPT" --validate-sparkle-distribution "$sparkle_tools_dir" >/dev/null

source_commit="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)" || fail "source commit could not be determined"
[[ "$source_commit" =~ ^[0-9a-fA-F]{40}$ ]] || fail "source commit is malformed"
if [[ -z "${TOKENTANK_SOURCE_HASH:-}" && -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    fail "worktree is not clean; supply TOKENTANK_SOURCE_HASH for an explicitly identified local candidate"
fi

read -r version build < <("$PYTHON" - "$app/Contents/Info.plist" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    with path.open("rb") as stream:
        info = plistlib.load(stream)
except (OSError, plistlib.InvalidFileException, ValueError) as error:
    raise SystemExit(f"cannot read app Info.plist: {error}")
version = info.get("CFBundleShortVersionString")
build = info.get("CFBundleVersion")
executable = info.get("CFBundleExecutable")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
    raise SystemExit("CFBundleShortVersionString must be numeric")
if not isinstance(build, str) or not re.fullmatch(r"[0-9]+", build):
    raise SystemExit("CFBundleVersion must be numeric")
if not isinstance(executable, str) or not re.fullmatch(r"[^/]+", executable):
    raise SystemExit("CFBundleExecutable is missing or unsafe")
print(version, build)
PY
) || fail "app metadata is invalid"
[[ -n "$version" && -n "$build" ]] || fail "app metadata is incomplete"

# Keep all temporary work outside the source app and publish only after every
# signing and validation step succeeds.
tmp_root="$(mktemp -d "$output_dir/.token-jar-release.XXXXXXXX")"
cleanup() {
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT

sparkle_extract="$tmp_root/sparkle"
mkdir -p -- "$sparkle_extract"
/usr/bin/tar -xf "$archive" -C "$sparkle_extract"

sparkle_framework_source="$sparkle_extract/Sparkle.framework"
generate_appcast="$sparkle_extract/bin/generate_appcast"
generate_keys="$sparkle_extract/bin/generate_keys"
sign_update="$sparkle_extract/bin/sign_update"
for tool in "$generate_appcast" "$generate_keys" "$sign_update"; do
    [[ -x "$tool" ]] || fail "pinned Sparkle tool is not executable: $tool"
done
[[ -d "$sparkle_framework_source" ]] || fail "pinned Sparkle framework extraction failed"

stage_root="$tmp_root/stage"
mkdir -p -- "$stage_root"
stage_app="$stage_root/$(basename -- "$app")"
/usr/bin/ditto "$app" "$stage_app"
[[ -d "$stage_app/Contents/Resources" ]] || fail "staged app has no Resources directory"
/usr/bin/ditto "$REPO_ROOT/LICENSE" "$stage_app/Contents/Resources/LICENSE"
/usr/bin/ditto "$REPO_ROOT/THIRD_PARTY_NOTICES" "$stage_app/Contents/Resources/THIRD_PARTY_NOTICES"

host_entitlements="$tmp_root/host-entitlements.plist"
"$PYTHON" - "$host_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(
    plistlib.dumps(
        {"com.apple.security.cs.disable-library-validation": True},
        fmt=plistlib.FMT_XML,
        sort_keys=True,
    )
)
PY

# Audit the unsigned build before signing so a malformed framework cannot be
# hidden by a later outer signature.
"$PYTHON" "$AUDIT_SCRIPT" \
    --app "$stage_app" \
    --mode unsigned \
    --entitlements "$host_entitlements" \
    --sparkle-distribution "$sparkle_tools_dir" \
    --source-commit "$source_commit" \
    --source-hash "${TOKENTANK_SOURCE_HASH:-}" >/dev/null

public_key="$("$generate_keys" --account "$SPARKLE_ACCOUNT" -p)" || fail "Sparkle public-key lookup failed"
[[ "$public_key" == "$SPARKLE_PUBLIC_KEY" ]] || fail "Keychain public key does not match app SUPublicEDKey"

sign_code() {
    [[ -e "$1" ]] || fail "Sparkle code object is missing: $1"
    /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$1"
}

framework="$stage_app/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" && ! -L "$framework" ]] || fail "staged app has no Sparkle.framework"
# Sign nested code from the innermost executable outwards.  Signing both the
# executable and its containing bundle prevents an outer signature from hiding
# an unsigned nested payload.
sign_code "$framework/Versions/B/Updater.app/Contents/MacOS/Updater"
sign_code "$framework/Versions/B/Updater.app"
sign_code "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
sign_code "$framework/Versions/B/XPCServices/Downloader.xpc"
sign_code "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
sign_code "$framework/Versions/B/XPCServices/Installer.xpc"
sign_code "$framework/Versions/B/Autoupdate"
sign_code "$framework/Versions/B/Sparkle"
sign_code "$framework"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$host_entitlements" "$stage_app"

"$PYTHON" "$AUDIT_SCRIPT" \
    --app "$stage_app" \
    --mode signed \
    --entitlements "$host_entitlements" \
    --sparkle-distribution "$sparkle_tools_dir" \
    --source-commit "$source_commit" \
    --receipt "$tmp_root/RELEASE_RECEIPT.json" \
    --source-hash "${TOKENTANK_SOURCE_HASH:-}" >/dev/null

feed_dir="$tmp_root/feed"
mkdir -p -- "$feed_dir"
temp_zip="$feed_dir/$output_name"
/usr/bin/ditto -c -k --keepParent "$stage_app" "$temp_zip"
[[ -s "$temp_zip" ]] || fail "ditto did not produce a ZIP"

# Sign and verify the archive before asking generate_appcast to sign the feed.
# The signature is public metadata; no private key material is captured.
zip_signature="$("$sign_update" --account "$SPARKLE_ACCOUNT" -p "$temp_zip")" || fail "Sparkle ZIP signing failed"
[[ "$zip_signature" =~ ^[A-Za-z0-9+/=]+$ ]] || fail "Sparkle ZIP signature is malformed"
"$sign_update" --account "$SPARKLE_ACCOUNT" --verify "$temp_zip" "$zip_signature"

release_prefix="$RELEASE_REPOSITORY/releases/download/v${version}/"
temp_appcast="$feed_dir/appcast.xml"
"$generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$release_prefix" \
    --maximum-deltas 0 \
    --versions "$build" \
    -o "$temp_appcast" \
    "$feed_dir"
[[ -s "$temp_appcast" ]] || fail "generate_appcast did not produce appcast.xml"
"$sign_update" --account "$SPARKLE_ACCOUNT" --verify "$temp_appcast"

"$PYTHON" - "$temp_appcast" "$temp_zip" "$version" "$build" "$release_prefix" "$zip_signature" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

feed_path, zip_path, version, build, prefix, signature = sys.argv[1:]
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
try:
    root = ET.parse(feed_path).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"cannot parse generated appcast: {error}")
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"generated appcast must contain exactly one update item, found {len(items)}")
item = items[0]
version_node = item.find(f"{{{namespace}}}version")
short_node = item.find(f"{{{namespace}}}shortVersionString")
enclosure = item.find("enclosure")
if version_node is None or version_node.text != build:
    raise SystemExit("appcast sparkle:version does not match CFBundleVersion")
if short_node is None or short_node.text != version:
    raise SystemExit("appcast sparkle:shortVersionString does not match CFBundleShortVersionString")
if enclosure is None:
    raise SystemExit("generated appcast has no enclosure")
expected_url = prefix + Path(zip_path).name
if enclosure.get("url") != expected_url:
    raise SystemExit(f"appcast enclosure URL is not canonical: {enclosure.get('url')!r}")
if enclosure.get("length") != str(Path(zip_path).stat().st_size):
    raise SystemExit("appcast enclosure length does not match ZIP")
if enclosure.get(f"{{{namespace}}}edSignature") != signature:
    raise SystemExit("appcast enclosure signature does not match independently signed ZIP")
if item.find(f"{{{namespace}}}delta") is not None:
    raise SystemExit("appcast unexpectedly contains a delta despite --maximum-deltas 0")
raw = Path(feed_path).read_text(encoding="utf-8")
if "sparkle-signatures:" not in raw or "edSignature:" not in raw:
    raise SystemExit("appcast has no embedded Sparkle feed signature")
PY

sha256="$($PYTHON - "$temp_zip" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
printf '%s  %s\n' "$sha256" "$output_name" > "$tmp_root/SHA256SUMS"

# Same-filesystem exclusive links publish complete files without overwriting
# anything created after the early output guard. A failure is never success.
"$PYTHON" - "$temp_zip" "$output" "$temp_appcast" "$appcast" \
    "$tmp_root/SHA256SUMS" "$checksums" "$tmp_root/RELEASE_RECEIPT.json" "$receipt" <<'PY'
import os
import sys
for source, destination in zip(sys.argv[1::2], sys.argv[2::2]):
    os.link(source, destination)
PY
printf 'Packaged %s (version %s, build %s)\n' "$output" "$version" "$build"
printf 'SHA-256 %s\n' "$sha256"
printf 'Signed feed %s\n' "$appcast"
printf 'Audit receipt %s\n' "$receipt"
printf 'Source base revision %s (see receipt for provenance limits)\n' "$source_commit"
