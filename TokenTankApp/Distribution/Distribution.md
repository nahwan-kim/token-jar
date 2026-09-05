# Token Tank direct distribution runbook

This is an operator template, not release evidence. A checked item records work performed by the operator; this document never asserts that a release passed. Replace every `{{PLACEHOLDER}}` before running a command and retain the command output with the release evidence. Do not commit filled-in credentials, private keys, notarization profiles, or unredacted logs.

## Operator placeholders

| Placeholder | Required value (record outside the repository) |
| --- | --- |
| `{{VERSION}}` | Marketing version of this candidate. |
| `{{BUILD_NUMBER}}` | Build number of this candidate. |
| `{{BUNDLE_ID}}` | Exact application bundle identifier. |
| `{{TEAM_ID}}` | Apple Developer Team ID. |
| `{{DEVELOPER_IDENTITY}}` | Full installed `Developer ID Application: ... ({{TEAM_ID}})` identity. |
| `{{DEVELOPER_ID_PROFILE_SPECIFIER}}` | Installed Developer ID provisioning profile that authorizes the exact app identifier used as the data-protection Keychain default group. |
| `{{NOTARY_KEYCHAIN_PROFILE}}` | Local Keychain profile name for `notarytool`; never the password or API key. |
| `{{ARCHIVE_PATH}}` | New, unambiguous `.xcarchive` path outside the repository. |
| `{{EXPORT_OPTIONS_PLIST}}` | Operator-maintained export-options plist path. |
| `{{EXPORT_PATH}}` | Empty export directory for this candidate. |
| `{{APP_PATH}}` | Exported `Token Tank.app` path. |
| `{{ARTIFACT_PATH}}` | Final DMG (preferred) or ZIP path. |
| `{{ARTIFACT_FILENAME}}` | Filename served at the official URL. |
| `{{OFFICIAL_DOWNLOAD_URL}}` | HTTPS URL owned by the project for this exact artifact. |
| `{{ARTIFACT_SHA256}}` | 64-hex SHA-256 published with the artifact. |
| `{{DESIGNATED_REQUIREMENT}}` | Requirement captured from `codesign -d -r-`; do not hand-edit it. |
| `{{NOTARY_REQUEST_UUID}}` | Actual notary request ID returned for this artifact. |
| `{{ROLLBACK_DIRECTORY}}` | Explicit local directory retaining the last known-good app. |
| `{{EVIDENCE_DIRECTORY}}` | Immutable release evidence directory for this candidate. |

## Native Codex account setup

Token Tank collects the existing `~/.codex` login and an optional second login in `~/.codex-secondary` through separate official `codex app-server` processes. GJC is not required. Do not copy or swap authentication files. The Codex CLI owns credential storage and refresh; Token Tank never opens those files.

To add the second account without replacing the first, run the following in a terminal and choose the other ChatGPT account in the browser:

```sh
mkdir -p "$HOME/.codex-secondary"
chmod 700 "$HOME/.codex-secondary"
CODEX_HOME="$HOME/.codex-secondary" codex -c 'cli_auth_credentials_store="file"' login
CODEX_HOME="$HOME/.codex-secondary" codex -c 'cli_auth_credentials_store="file"' login status
```

Treat `~/.codex-secondary/auth.json` as a password: never paste, commit, or export it. Verify the two account emails in the popup; login status alone does not establish different identities. Missing secondary directories are not errors, and a failed secondary refresh must not replace the first account's healthy data. The compact Codex panel shows `email · plan`, one general weekly quota in column 1, and remaining reset-ticket count plus only the nearest future expiry in column 2. Spark is not displayed. The menu shows ordered remaining percentages separated by a middle dot, without aliases or email labels; percentages are never added or averaged. Every provider shows elapsed minutes since its last successful refresh beside its status LED; missing timestamps remain unavailable.

The popup header's **Open in Window** button opens a resizable standalone usage window. It shares the popup's data and refresh cycle, remains open when focus moves elsewhere, and reuses the same window on repeated clicks. Closing that window leaves the menu-bar app running; the header button can reopen it. This is a normal desktop window, not an always-on-top overlay.

## Preconditions and hard stops

- Use a clean, physical macOS 14+ host and the pinned Xcode/Swift toolchain from CI. Record `sw_vers`, `xcodebuild -version`, `swift --version`, host model, and the candidate source revision in `{{EVIDENCE_DIRECTORY}}`.
- Install a **Developer ID Application** certificate whose identity exactly fills `{{DEVELOPER_IDENTITY}}`. Keep its private key in the macOS Keychain; never export or place it in the repository.
- Install the Developer ID provisioning profile named by `{{DEVELOPER_ID_PROFILE_SPECIFIER}}`; its application identifier must be exactly `{{TEAM_ID}}.{{BUNDLE_ID}}`. Do not enable a shared Keychain group.
- Configure `{{NOTARY_KEYCHAIN_PROFILE}}` locally with `xcrun notarytool store-credentials` or an approved CI secret store. Do not put Apple IDs, issuer IDs, API keys, passwords, or profile contents in command history, workflow YAML, artifacts, or logs.
- Confirm the product is menu-bar-only (`LSUIElement`), has no App Sandbox entitlement, and enables Hardened Runtime for Release. The app must contain no updater, browser/WebKit runtime, login item, XPC/helper payload, or privileged installer.
- Confirm Release coverage instrumentation is disabled, dead code and installed symbols are stripped, and the final executable contains both `arm64` and `x86_64` without an absolute user-home build path.
- Confirm the source and exported binary do not directly call listed FileTimestamp required-reason APIs and the manifest does not claim `3B52.1` for the fixed Cursor.app path. Stop release if a later toolchain scan reports an undeclared or mismatched required-reason API.
- Stop on any unresolved source/path/permission, accepted-source live validation, security, signing, entitlement, import, notarization, or Gatekeeper finding. Do not weaken Hardened Runtime or substitute an unsigned artifact.

## AC-01–AC-16 evidence reconciliation

This is the authoritative evidence map, not a pass claim. Automated rows are re-established by the named gates for each frozen revision. A row with remaining owner or release evidence stays open even when its automated gate passes.

| AC | Automated/source-tree evidence | Evidence still required before v1 release |
| --- | --- | --- |
| AC-01 | `TokenTankUITests.testMenuBarAccessibilityAndTermination` checks the five-Provider one-line accessible summary, fixed order, abbreviations, and selected percentages. | Final signed-candidate UI rerun. |
| AC-02 | `AppModelTests` covers explicit representative selection, vanished IDs without substitution, ordering, visibility, abbreviation, and preference persistence; Settings renders the frozen unavailable state/action. | Final signed-candidate Settings smoke test. |
| AC-03 | Five adapter suites assert exact fixture records, optional/zero preservation, raw fields, stable opaque IDs, and no merge. | Sanitized owner-controlled live checklist for all five accepted surfaces. |
| AC-04 | Domain/adapter suites and the bilingual UI matrix cover original names, exact source values, direction, reset/freshness, literal zero, and `Not provided` / `제공 안 됨`. | Final signed-candidate bilingual smoke test. |
| AC-05 | `RefreshCoordinator` fake-clock tests cover five-minute cadence, manual coalescing, cancellation, and no overlapping refresh storm. | Normal five-minute terminal-state observation in the frozen AC-11 runs. |
| AC-06 | Coordinator/AppModel tests cover process-lifetime last-good stale retention, typed cause/action, retry, stop cleanup, and relaunch from `neverLoaded`; no snapshot store exists. | Final process-lifecycle observation on the signed candidate. |
| AC-07 | Exact scoped capabilities, descriptor-bound immutable Cursor reads, owner-session fixtures, mutation assertions, and `Scripts/audit-provider-io.sh` enforce external-owner non-mutation. | Final Cursor owner-path actual-open facts before/after on the frozen candidate. |
| AC-08 | Closed `CollectionError` mappings and bilingual UI states keep login actions limited to explicit rejection/revocation or missing owner session. | Owner-controlled rejection/session-loss checks for accepted live surfaces. |
| AC-09 | Keychain tests enforce the data-protection Keychain, fixed accessibility class, app-owned identifier allowlist, value bounds, no plaintext fallback, delete/update behavior, and stale mapping. | Locked-since-boot/unavailable behavior with the final Developer ID identity. |
| AC-10 | Release build settings, `LSUIElement`, dependency/payload/import/leak scans, and the UI termination test enforce no Dock/browser/updater/helper and a stripped universal artifact. | Repeat against the signed/stapled artifact. |
| AC-11 | `Scripts/measure-idle.sh` validates sample count, cadence, stable PID, CPU/RSS arithmetic, drift, and artifact identity without claiming release sign-off. | Three independent physical reference-host runs with all five Providers reaching terminal state. |
| AC-12 | The deterministic XCUITest matrix exposes all five groups plus fresh, stale, authentication, permission, offline, missing, zero, direction, reset/freshness, and recovery controls. | Final signed-candidate XCUITest rerun. |
| AC-13 | `ProviderSources.json`, registry tests, source docs, and fixed network/process boundaries encode one selected surface per Provider; CodexBar is reference-only and the rejected Grok ACP path is inactive. | Capture final documentation revisions and owner-controlled live shapes. |
| AC-14 | Release/CI gates require universal stripped code, Hardened Runtime, no App Sandbox/updater, exact payload scans, and a source-commit/source-hash plus binary digest receipt with explicit scan outcomes; this runbook fixes manual replacement/provenance. | Developer ID archive/export, notarization response, staple, official HTTPS artifact/digest, and clean-host Gatekeeper evidence. |
| AC-15 | Exact path/operation capability tests, static Provider I/O audit, descriptor-bound SQLite, Keychain/network bounds, memory-only lifecycle, privacy manifest gate, and empty source entitlements fail closed. | Frozen actual-open/TCC matrix plus final signed security/privacy review. |
| AC-16 | Deployment target and CI include macOS 14/current; the catalog gate requires exactly English/Korean translations, and XCUITests cover English, Korean, accessibility, layout matrix, and unknown-language English fallback. | Successful frozen CI matrix and signed-candidate locale rerun. |

AC-01 through AC-16 are conjunctive. The unchecked external cells above are hard release stops and feed the operator sign-off record below.

The Settings language picker switches English/한국어 immediately across open windows and persists the selection. On first launch, Korean system language selects Korean; other languages select English. Quota reset countdowns use elapsed days and whole hours (under one hour is explicit), while reset-ticket expirations show full local dates, times, and time zones. Missing expiration data is not inferred.

## Archive with Developer ID and Hardened Runtime

Use an empty archive path for each candidate. Manual signing avoids accidentally selecting a development identity. The command below is a procedure, not a pass assertion:

```sh
xcodebuild \
  -project TokenTank.xcodeproj \
  -scheme TokenTank \
  -configuration Release \
  -archivePath "{{ARCHIVE_PATH}}" \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="{{DEVELOPER_IDENTITY}}" \
  DEVELOPMENT_TEAM="{{TEAM_ID}}" \
  PROVISIONING_PROFILE_SPECIFIER="{{DEVELOPER_ID_PROFILE_SPECIFIER}}" \
  PRODUCT_BUNDLE_IDENTIFIER="{{BUNDLE_ID}}" \
  CURRENT_PROJECT_VERSION="{{BUILD_NUMBER}}" \
  MARKETING_VERSION="{{VERSION}}" \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  DEPLOYMENT_POSTPROCESSING=YES \
  DEAD_CODE_STRIPPING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES
```

Record the complete archive command, tool versions, and actual output. Do not record a success word without the corresponding command output. Inspect the archive before export:

```sh
/usr/bin/plutil -p "{{ARCHIVE_PATH}}/Info.plist"
/usr/bin/codesign --display --verbose=4 "{{ARCHIVE_PATH}}/Products/Applications/Token Tank.app"
/usr/bin/codesign --verify --deep --strict --verbose=4 "{{ARCHIVE_PATH}}/Products/Applications/Token Tank.app"
/usr/bin/security cms -D -i "{{ARCHIVE_PATH}}/Products/Applications/Token Tank.app/Contents/embedded.provisionprofile"
/usr/bin/lipo -archs "{{ARCHIVE_PATH}}/Products/Applications/Token Tank.app/Contents/MacOS/Token Tank"
```

## Export the distributable artifact

Maintain `{{EXPORT_OPTIONS_PLIST}}` outside this repository and review it with the security record. It must select Developer ID distribution and must not introduce an updater, helper, App Sandbox, or broad temporary exception. The operator supplies the exact plist used for this candidate:

```sh
/usr/bin/xcodebuild -exportArchive \
  -archivePath "{{ARCHIVE_PATH}}" \
  -exportOptionsPlist "{{EXPORT_OPTIONS_PLIST}}" \
  -exportPath "{{EXPORT_PATH}}"
```

For a DMG, package only the verified app using the operator's reviewed packaging procedure. For a ZIP, staple and validate the app before creating the ZIP; retain the exact packaging command and file list. Do not include credentials, source fixtures, diagnostic logs, CI state, or an updater/helper in either artifact.

## Signature, entitlements, imports, and designated requirement

Run these checks on the exported app and record unedited output. The designated requirement is evidence to compare, not a value to invent:

```sh
/usr/bin/codesign --display --verbose=4 "{{APP_PATH}}"
/usr/bin/codesign --verify --deep --strict --verbose=4 "{{APP_PATH}}"
/usr/bin/codesign -d --entitlements :- "{{APP_PATH}}"
/usr/bin/security cms -D -i "{{APP_PATH}}/Contents/embedded.provisionprofile"
/usr/bin/codesign -d -r- --verbose=4 "{{APP_PATH}}"
/usr/bin/otool -L "{{APP_PATH}}/Contents/MacOS/Token Tank"
```

Record the exact designated requirement as `{{DESIGNATED_REQUIREMENT}}`, signer, Team ID, bundle identifier, and signing flags. Compare entitlements against the approved matrix:

- Hardened Runtime is present (`ENABLE_HARDENED_RUNTIME=YES`).
- `com.apple.security.app-sandbox` is absent for v1.
- The embedded Developer ID profile and final entitlements authorize exactly `{{TEAM_ID}}.{{BUNDLE_ID}}` as the default data-protection Keychain group; no extra shared Keychain group is present.
- JIT, unsigned executable memory, library-validation bypass, automation, Apple Events, privileged helper, and broad temporary exceptions are absent unless separately approved (none are expected for v1).
- The app and every nested code object are signed by the intended Developer ID identity.
- `otool -L`, nested bundles, and payload names contain no WebKit/browser framework, Sparkle/updater framework, update agent, login item, XPC/helper, or privileged installer.

Any mismatch is a release stop. Do not repair a signature by deleting entitlements after signing; return to the archive/export inputs and retain the failed evidence.

## Notarize, staple, and assess with Gatekeeper

Submit the exact final artifact, preferably a DMG. The Keychain profile is a reference only; it is not a secret in this document:

```sh
xcrun notarytool submit "{{ARTIFACT_PATH}}" \
  --keychain-profile "{{NOTARY_KEYCHAIN_PROFILE}}" \
  --wait
```

Record the actual request identifier as `{{NOTARY_REQUEST_UUID}}` and retain the full status output. A rejected, timed-out, or unknown status stops distribution. Do not write “accepted” here unless the retained Apple response says so.

For a DMG, staple and validate the DMG. For a ZIP, staple and validate the app before packaging and retain both app and archive hashes:

```sh
xcrun stapler staple -v "{{ARTIFACT_PATH}}"
xcrun stapler validate -v "{{ARTIFACT_PATH}}"
spctl --assess --type execute --verbose=4 "{{APP_PATH}}"
spctl --assess --type open --context context:primary-signature --verbose=4 "{{ARTIFACT_PATH}}"
```

Run the final checks on a clean macOS 14+ host with quarantine preserved. Never remove quarantine attributes, disable Gatekeeper, disable SIP, alter TCC databases, or grant broad access as a workaround. Record actual Gatekeeper/stapler output and host facts; a command that was not run remains unresolved.

## SHA-256 and official provenance

Compute the digest after stapling and packaging. Publish the exact 64-hex result at the same official HTTPS location as the artifact:

```sh
/usr/bin/shasum -a 256 "{{ARTIFACT_PATH}}"
```

The release record must contain:

```text
Version: {{VERSION}}
Build: {{BUILD_NUMBER}}
Artifact filename: {{ARTIFACT_FILENAME}}
Artifact SHA-256: {{ARTIFACT_SHA256}}
Official download URL: {{OFFICIAL_DOWNLOAD_URL}}
Developer ID identity: {{DEVELOPER_IDENTITY}}
Bundle ID: {{BUNDLE_ID}}
Team ID: {{TEAM_ID}}
Designated requirement: {{DESIGNATED_REQUIREMENT}}
Notary request: {{NOTARY_REQUEST_UUID}}
```

Before publishing, verify the URL is HTTPS and project-controlled; an HTTP URL, redirect to an unreviewed host, mutable “latest” object, missing digest, mismatched filename, or digest mismatch is a stop:

```sh
case "{{OFFICIAL_DOWNLOAD_URL}}" in
  https://*) : ;;
  *) printf '%s\n' 'STOP: official distribution URL must use HTTPS' >&2; exit 1 ;;
esac
```

Do not place a release claim in this guide. The operator attaches the actual provenance record and approval separately.

## Manual replacement and rollback (no updater)

Token Tank v1 has **no** in-app updater, update framework, feed check, background update agent, login item, privileged installer, or update signing key. There is no automatic download or replacement path.

1. Download `{{ARTIFACT_FILENAME}}` only from `{{OFFICIAL_DOWNLOAD_URL}}` using an HTTPS-capable client.
2. Compare the downloaded SHA-256 with `{{ARTIFACT_SHA256}}`; reject a mismatch. Verify Developer ID identity, designated requirement, staple, and Gatekeeper result on the downloaded artifact before opening it.
3. Quit Token Tank. Keep the current app untouched in `{{ROLLBACK_DIRECTORY}}` (or use a versioned Finder directory); do not delete it before the replacement is verified.
4. Move the verified `Token Tank.app` into the reviewed installation location and launch it once manually. Do not run two copies during replacement. Validate bundle identity and signature again after the move.
5. If launch, signature, notarization, or source behavior is wrong, quit the candidate and restore the retained prior app from `{{ROLLBACK_DIRECTORY}}`. Re-run signature and Gatekeeper checks; retain both candidate and rollback evidence. Do not use `rm -rf`, an updater helper, or permission changes as a recovery step.

A future updater would require a new threat model, dependency/license review, feed and update-signing design, key custody, rollback plan, privacy disclosure, Hardened Runtime review, and explicit approval. It cannot be introduced as packaging cleanup.

## Secret and evidence handling

- Developer ID private keys, Apple notarization credentials, provider tokens, cookies, CLI sessions, and Keychain profile material remain in their owning Keychain or approved secret store.
- Ordinary CI must not receive signing, notarization, or provider credentials. Release-only jobs use protected credentials and do not echo them.
- Redact headers, cookies, account identifiers, raw provider responses, paths containing personal names, and Keychain output from evidence. Do not commit filled placeholders or unredacted command transcripts.
- Store release evidence under `{{EVIDENCE_DIRECTORY}}` with restricted operator access. Include artifact bytes or an immutable external reference, SHA-256, command output, tool versions, signer/designated requirement, notarization response, stapler/Gatekeeper output, and security sign-off.
- Scan the archive, artifact staging directory, logs, fixtures, and evidence for seeded canaries and secret-shaped values before publication. A finding blocks distribution; do not “fix” evidence by hiding the line.

## Operator sign-off record

Leave each item unchecked until the corresponding evidence is attached. This checklist is intentionally unresolved by default:

- [ ] `{{ARCHIVE_PATH}}` was produced from the intended revision with pinned Xcode/Swift.
- [ ] Release archive/export used `{{DEVELOPER_IDENTITY}}`, `{{TEAM_ID}}`, `{{DEVELOPER_ID_PROFILE_SPECIFIER}}`, and Hardened Runtime.
- [ ] Entitlements, nested signatures, designated requirement, imports, and payload scan match `SecurityReview.md`.
- [ ] `{{ARTIFACT_PATH}}` was notarized; Apple response and `{{NOTARY_REQUEST_UUID}}` are retained.
- [ ] Stapler validation and clean-host Gatekeeper output are retained.
- [ ] `{{ARTIFACT_SHA256}}` matches the published artifact at `{{OFFICIAL_DOWNLOAD_URL}}`.
- [ ] Manual replacement and rollback were reviewed; no updater/helper exists.
- [ ] Security, privacy, TCC/FDA, and all five Provider source gates are signed off without unresolved blockers.

Operator: `{{RELEASE_OWNER}}`  Date (with offset): `{{SIGNOFF_TIMESTAMP}}`

No checkbox above is a release assertion until a responsible reviewer signs the external evidence record.
