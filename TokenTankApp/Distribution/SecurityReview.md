# Token Tank security and privacy review

This is a release-gate template. It records required evidence and unresolved questions; it does not claim that a build, Provider, permission, or release passed. Replace `{{PLACEHOLDER}}` only in an external review record. Never put credentials, cookies, raw quota responses, or personal paths in this file.

## Review identity and decision

| Field | Operator value |
| --- | --- |
| Candidate version/build | `{{VERSION}}` / `{{BUILD_NUMBER}}` |
| Source revision | `{{SOURCE_REVISION}}` |
| Artifact SHA-256 | `{{ARTIFACT_SHA256}}` |
| Bundle ID / Team ID | `{{BUNDLE_ID}}` / `{{TEAM_ID}}` |
| Developer ID identity | `{{DEVELOPER_IDENTITY}}` |
| Review evidence directory | `{{EVIDENCE_DIRECTORY}}` |
| Security reviewer | `{{SECURITY_REVIEWER}}` |
| Review date (with offset) | `{{REVIEW_TIMESTAMP}}` |
| Decision | `UNRESOLVED — do not publish until every blocker is closed` |

A release is blocked by any blank required cell, failed command, unreviewed path, unapproved permission, direct Provider I/O, secret finding, entitlement/import mismatch, or unresolved Provider-source decision.

## Provider source, path, permission, and TCC/FDA matrix

Complete one row for every source actually used. “Official” applies only to the provider-owned, documented boundary; an undocumented method, endpoint, or storage layout remains explicitly labeled `watch` even when reached through an official client. Organization, team, and billing surfaces retain their real names and never masquerade as consumer quota. CodexBar is reference-only: Token Tank does not copy its code, browser-cookie imports, credential caches, PTY automation, estimates, or fallback chains.

| Provider / source kind | Official documentation URL + revision/date | Exact endpoint or canonical path/pattern | Owner that writes/rotates it | Exact files/records and raw fields | Read capability/API + read-only flags | Symlink/canonical-containment proof | Permission class / TCC or FDA location | FDA or broad grant required? | User-initiated explanation and pane | Denial/revocation behavior | Before/after immutability evidence | Reviewer/status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Codex / official app-server | `https://developers.openai.com/codex/app-server/` / `{{CODEX_DOC_REVISION}}` | `account/rateLimits/read` over the allowlisted `codex app-server` stdio boundary | Codex CLI owns and rotates its session | every keyed primary/secondary `usedPercent`, exact arithmetic complement, duration/reset, balance credit, and reset-credit record | narrow size/time-bounded Core `CodexAccountUsageReader`; no auth mutation methods | allowlisted executable candidates only | none identified | no | not applicable | missing executable/session requests source-owner setup; generic RPC failure remains stale | live sanitized shape validated; final frozen rerun and owner-store review pending | **SOURCE ACCEPTED — live shape validated** |
|| Claude / Claude Code local usage cache | `https://www.onorca.dev/docs/agents/usage-tracking` / current | `cachedUsageUtilization` in `~/.claude.json` | Claude Code owns and rotates the local cache | session, weekly_all, weekly_scoped, and named window utilization plus source reset timestamps | exact external-session read of `~/.claude.json`; no Admin API, no credential copy | canonical home path, no recursive scan | none identified | no | not applicable | missing cache requests Claude Code login; schema failure remains stale | no mutation | **WATCH — local Claude Code usage cache; never Admin API or OAuth/PTY** |
|| Grok / Grok CLI SuperGrok credits | `https://github.com/steipete/CodexBar/blob/main/docs/grok.md` / current | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` after a read-only `~/.grok/auth.json` open | Grok CLI owns and rotates the session | published `creditUsagePercent` or same-row on-demand used/cap ratio, plus source reset timestamps | exact external-session read of `~/.grok/auth.json` plus exact HTTPS destination; the token exists only in the ephemeral request | canonical owner path | none identified | no | not applicable | missing/expired/rejected session requests `grok login`; schema failure remains stale | no mutation | **WATCH — CodexBar SuperGrok credits path; never cookies, ACP stdio, or Management prepaid balance** |
| Cursor / immutable Cursor.app owner session | Cursor usage/limits docs and CodexBar Cursor reference / `{{CURSOR_DOC_REVISION}}` | `ItemTable[cursorAuth/accessToken]` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` opened with `immutable=1`, then `GET https://cursor.com/api/usage-summary` | Cursor.app owns and rotates the JWT | billing cycle/type flags; individual plan/on-demand/overall, team on-demand/pooled, plan breakdown, and source percentages as independent records | exact immutable SQLite capability plus exact HTTPS destination; the token envelope/subject/expiry are bounded locally, while the Provider endpoint decides authentication; the token exists only in the ephemeral request | canonical owner path opened with `O_NOFOLLOW`, opened-descriptor identity check, descriptor-bound `/dev/fd` SQLite with `SQLITE_OPEN_NOFOLLOW`, fixed DB/table/key, ordinary-table and duplicate-row rejection | current host immutable open succeeded without TCC; final actual-open proof required | no broad grant observed; direct listed FileTimestamp APIs are absent and the manifest declares only UserDefaults | no System Settings request | missing/expired/rejected session requests source-owner login; I/O/schema failure remains stale | live main/WAL/SHM facts unchanged under immutable read; final frozen rerun pending | **WATCH — live shape validated; layout/endpoint undocumented** |
|| Doubao / official arkcli plan usage | `https://github.com/volcengine/ark-cli` / current | `arkcli usage plan --format json` over the allowlisted arkcli executable | arkcli owns and rotates SSO | every Coding/Agent plan window and source used/total/remaining/percentage/reset field; exact same-row remaining/percentage arithmetic only when omitted | narrow size/time-bounded Core `DoubaoPlanUsageReader`; no auth mutation methods | allowlisted executable candidates only | none identified | no | not applicable | missing executable/session requests `arkcli auth login`; generic CLI failure remains stale | no mutation | **WATCH — official arkcli plan usage; never OpenAPI AK/SK** |

### Accepted source decision and remaining live gates

The user delegated the source choice and approved CodexBar/Orca as a reference. The accepted production composition is Codex app-server, Claude Code local usage cache, Grok CLI SuperGrok credits, immutable Cursor.app session plus usage-summary, and official arkcli plan usage. Live probing rejected CodexBar’s Grok ACP `x.ai/billing` path because official Grok 1.0.13 returned JSON-RPC -32601 (method-not-found). This decision does not legitimize browser-cookie imports, credential caches, Claude OAuth/PTY paths, fallback merging, or estimates. Claude, Grok, Cursor, and Doubao remain `watch` because their local-session or CLI JSON layouts are undocumented; schema drift fails closed. Final release still requires owner-controlled live responses, terms/revision capture, actual-open immutability evidence, signing/notarization, clean-host verification, and AC-11 physical-host runs.

## Ownership and immutability contract

- Token Tank may write only app-owned generic-password Keychain items through the Core credential capability. It never writes, rotates, deletes, copies, exports, or migrates a CLI or browser session.
- External CLI/browser owners alone create and rotate their stores. Token Tank re-reads the canonical record in place after an owner update and reports missing/revoked sessions with the typed recovery state.
- External reads use the source-specific capability with canonical containment, no recursive discovery, no unreviewed symlink, no write-capable descriptor, and no metadata/content mutation. Provider code cannot instantiate filesystem, network, Security, process, WebKit, or browser APIs.
- Record before and after path identity, inode/file ID, size, modification time, permissions, owner, and cryptographic digest for a sanitized fixture. The expected result is unchanged content and metadata after every read. Do not use a real cookie or token for this test.

| Check | Fixture/path identifier | Before facts | Read operation | After facts | Expected result | Evidence / status |
| --- | --- | --- | --- | --- | --- | --- |
| Owner writes fixture | `{{FIXTURE_ID}}` | `{{BEFORE_FACTS}}` | owner-controlled update only | `{{AFTER_OWNER_UPDATE}}` | change belongs to owner | `{{OWNER_UPDATE_EVIDENCE}}` |
| Token Tank read | `{{FIXTURE_ID}}` | `{{BEFORE_FACTS}}` | `{{READ_CAPABILITY}}` with read-only mode | `{{AFTER_READ_FACTS}}` | bytes/metadata unchanged | `{{READ_IMMUTABILITY_EVIDENCE}}` |
| Missing/removed source | `{{FIXTURE_ID}}` | `{{PRESENT_FACTS}}` | source removed by owner | `{{MISSING_FACTS}}` | typed external-session-missing; no login unless contract says so | `{{MISSING_SOURCE_EVIDENCE}}` |
| Unsafe symlink/path escape | `{{SYMLINK_FIXTURE_ID}}` | `{{LINK_FACTS}}` | canonicalization attempt | `{{DENIAL_FACTS}}` | permission/path-unsafe; no follow or fallback scan | `{{SYMLINK_EVIDENCE}}` |

## App credentials and Keychain class

App-owned generic-password credentials use the data-protection Keychain (`kSecUseDataProtectionKeychain`) so the frozen `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` class is effective. Reads match that class and non-synchronizing storage exactly; a same-account item with weaker or synchronizing attributes is unavailable, never accepted as a credential, while explicit deletion remains limited to the same app-owned service/account. No plaintext, `UserDefaults`, files, logs, fixtures, crash payloads, environment exports, or provider-owned stores may contain an app credential.

| Case | Required behavior | Evidence |
| --- | --- | --- |
| Normal post-first-unlock read | Read only the app-owned item through Core; do not expose its value to diagnostics or Provider source code. | `{{KEYCHAIN_NORMAL_EVIDENCE}}` |
| Locked since boot / temporarily unavailable | Retain the process-lifetime snapshot as stale, retry next five-minute cycle, and never show login or delete/recreate the item. | `{{KEYCHAIN_LOCKED_EVIDENCE}}` |
| Explicit Provider rejection/revocation | Show the app-owned login action only when the Provider contract identifies rejection/revocation. | `{{KEYCHAIN_REVOKED_EVIDENCE}}` |
| Item deleted by the user | Show app credential setup; never conflate deletion with a temporary lock and never use a plaintext fallback. | `{{KEYCHAIN_DELETED_EVIDENCE}}` |
| Device migration/restore | `ThisDeviceOnly` item does not migrate; require setup on the new device. | `{{KEYCHAIN_MIGRATION_EVIDENCE}}` |

## Snapshot and persistence review

Provider snapshots, raw quota values/responses, reset times, error payloads, session data, correlation payloads, and last-known-good values are memory-only for v1. Relaunch begins `neverLoaded`; quitting clears snapshots. Only non-secret display preferences (visibility, order, representative raw quota ID, abbreviation) may persist in `UserDefaults`.

| Storage surface | Allowed data | Forbidden data | Check/evidence |
| --- | --- | --- | --- |
| Keychain | App-owned credentials, class above | External sessions, raw responses, quota snapshots | `{{KEYCHAIN_STORE_SCAN}}` |
| UserDefaults/preferences | Non-secret display settings only | Credentials, snapshot, raw response, errors, session data | `{{PREFERENCES_SCAN}}` |
| Files/cache/temp | No quota or session payloads | Any snapshot/response/error/auth material | `{{FILES_CACHE_SCAN}}` |
| Logs/crash reports | Redacted category, duration, result class, provider ID where safe | Tokens, cookies, headers, account IDs, raw values/responses | `{{LOG_PRIVACY_SCAN}}` |

## Static Provider boundary audit

Run the checked-in source audit without adding suppressions:

```sh
/bin/bash Scripts/audit-provider-io.sh
```

The audit is restricted to `Sources/CodexProvider`, `Sources/ClaudeProvider`, `Sources/GrokProvider`, `Sources/CursorProvider`, and `Sources/DoubaoProvider`. It must fail closed on direct `FileManager`, `FileHandle`, `Data(contentsOf:)`, `String(contentsOf:)`, POSIX file/open/metadata calls, `URLSession`, `URLRequest`, `Network`/`NW*`, sockets, `SecItem*`/Security, `Process`/shell APIs, `NSWorkspace`, `NSAppleScript`/Apple Events, WebKit/SafariServices, runtime reflection, dynamic loading, filesystem enumeration, and write/delete/rename/chmod/chown APIs. Parsing/value Foundation APIs and injected Core `NetworkRequest` are allowed.

Record the source revision, complete findings output, target file list, and review result. A Provider cannot suppress a finding or import a new dependency to bypass the boundary; move I/O to an audited Core/app composition capability or stop the lane.

| Static check | Expected result | Evidence |
| --- | --- | --- |
| Provider source target list exactly five | no missing/extra target; deterministic sorted scan | `{{STATIC_TARGET_EVIDENCE}}` |
| Forbidden imports/symbols | zero findings | `{{STATIC_FINDINGS_EVIDENCE}}` |
| Package dependency graph | Provider depends only on Domain and narrow Core capabilities | `{{PACKAGE_GRAPH_EVIDENCE}}` |
| Third-party/bundled runtime dependencies | none unless separately approved and reviewed | `{{DEPENDENCY_REVIEW}}` |

## Dynamic open, network, and mutation audit

Static scanning is defense-in-depth. Compose each Provider with recording capabilities and sanitized fixtures, then intercept actual operations. Compare every observed operation to the source/path matrix; an unlisted open, destination, descriptor mode, recursive traversal, symlink resolution, write, rename, delete, chmod, chown, Apple Event, process launch, or browser operation is a failure.

- Filesystem: record canonical path, open flags, file descriptor mode, byte range/maximum, symlink decision, and close. Only allow reviewed read-only opens. Do not use a generic home-directory scan.
- Network: record the injected `NetworkRequest` destination, method, headers class (never values), timeout, cancellation, response status, and body size. Do not permit Provider-created `URLSession`/`URLRequest` or direct `Network`/socket calls.
- Keychain: record only operation class and app-owned `CredentialID`; never record secret values. Provider targets must not call `SecItem*`.
- Process/browser/automation: Codex may start exactly one user-owned executable from the fixed candidate list with the literal `app-server` argument and bounded JSON-RPC I/O; record the resolved executable, fixed arguments, PID, deadline, and termination. Every other Provider process and every browser, WebKit, Apple Event, Automation, UI-scripting, `NSAppleScript`, or `NSWorkspace` operation has expected count zero.
- Mutation: hash and stat reviewed fixtures before and after. Expected content, metadata, owner, permissions, and directory entries are byte-for-byte/field-for-field unchanged.

| Dynamic scenario | Observed opens/destinations | Mutation/ownership result | Error mapping | Evidence |
| --- | --- | --- | --- | --- |
| Fresh success | `{{SUCCESS_OPERATIONS}}` | `{{SUCCESS_IMMUTABILITY}}` | none | `{{SUCCESS_DYNAMIC_EVIDENCE}}` |
| Owner atomic replacement | `{{OWNER_REPLACEMENT_OPERATIONS}}` | re-read new owner version; no lock/copy/write | `{{OWNER_REPLACEMENT_ERROR}}` | `{{OWNER_REPLACEMENT_EVIDENCE}}` |
| Offline/timeout/429 | `{{NETWORK_FAILURE_OPERATIONS}}` | no local mutation | stale/retry; no login | `{{NETWORK_FAILURE_EVIDENCE}}` |
| Permission denial/TCC revoke | `{{PERMISSION_OPERATIONS}}` | no fallback scan or workaround | permissionDenied/stale; frozen System Settings action | `{{PERMISSION_EVIDENCE}}` |
| Malformed/schema change | `{{SCHEMA_OPERATIONS}}` | no snapshot persistence | data-format/schema stale | `{{SCHEMA_EVIDENCE}}` |

## TCC/FDA permission stop gate

Discovery that a required source is TCC-protected, needs Full Disk Access, needs Files and Folders consent, or needs a similarly broad user grant **stops the affected Provider lane for separate explicit consensus**. It is not routine onboarding and is not waived by a successful local test. The reviewer must record exact location, minimum grant, user explanation, denial behavior, and why no narrower source exists before any approval.

- The request, if approved, is initiated by the user from the affected Provider setup/recovery surface and names the Provider, exact read-only quota purpose, and System Settings pane.
- Denial, revocation, or an unavailable permission maps to `permissionDenied`/stale, preserves the in-memory value, retries only on the next cycle or explicit retry, and never prompts login or silently skips the Provider.
- Token Tank never changes permissions or ownership and never edits, resets, disables, or bypasses TCC or SIP. Do not use `tccutil reset`, modify the TCC database, disable SIP, inject entitlements, grant Terminal-wide access, or instruct the user to weaken system protections.
- Browser automation, interactive CLI driving, PTY scraping, and Apple Events are forbidden. The approved Codex app-server boundary is a provider-documented JSON-RPC server that may receive only the methods recorded above; it is not UI automation.

| Provider | Exact protected location | Minimum requested permission | Why narrower read is impossible | User explanation/pane | Denial/revocation | Consensus decision |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | allowlisted CLI executable only; Token Tank does not open the Codex credential store | none | official app-server owns credential access | no System Settings request | missing/revoked owner session requests Codex login; generic failure stays stale | no TCC/FDA grant approved |
|| Claude | `~/.claude.json` | none | Claude Code owns credential access; Token Tank reads only the usage cache | no System Settings request | missing/revoked owner cache requests Claude Code login; generic failure stays stale | no TCC/FDA grant required |
|| Grok | `~/.grok/auth.json` | none | Grok CLI owns credential access; Token Tank reads only the owner session then the CLI-proxy credits endpoint | no System Settings request | missing/expired/rejected owner session requests `grok login`; generic failure stays stale | no TCC/FDA grant required |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` and active SQLite sidecars | none observed; final candidate actual-open proof pending | immutable fixed-record read avoids browser stores and SQLite lock/SHM mutation | no System Settings request | permission denial remains stale and stops the lane; no fallback or broad prompt | no broad grant approved; current-host immutable open succeeded |
|| Doubao | allowlisted arkcli executable only; Token Tank does not open the Volcengine credential store | none | official arkcli owns credential access | no System Settings request | missing/revoked owner session requests `arkcli auth login`; generic failure stays stale | no TCC/FDA grant required |

## Logs, fixtures, archive, and secret scan

Use sanitized fixtures with unique canary values held outside the repository. Scan source, package build output, archive, exported app, DMG/ZIP staging, logs, crash reports, preferences, evidence, and CI artifacts. Retain command, tool version, scope, pattern class, and result; never retain the canary secret itself.

| Surface | Scan scope | Secret classes | Expected result | Evidence |
| --- | --- | --- | --- | --- |
| Source/fixtures | repository and test resources | seeded canaries, API-key/token/cookie-shaped values, account IDs | zero findings | `{{SOURCE_SECRET_SCAN}}` |
| Build/archive/export | `.xcarchive`, app, frameworks, resources | same plus embedded credentials/private keys | zero findings | `{{ARCHIVE_SECRET_SCAN}}` |
| Logs/crash/diagnostics | collected runtime output | headers, cookies, raw responses, paths, identifiers | zero findings; redaction verified | `{{LOG_SECRET_SCAN}}` |
| Evidence/CI artifacts | `{{EVIDENCE_DIRECTORY}}`, workflow artifacts | credentials, tokens, unredacted requests | zero findings | `{{EVIDENCE_SECRET_SCAN}}` |

A finding blocks the release. Do not hide, truncate, or delete a failing line to obtain a clean scan; rotate any test credential and repeat the full review.

## Entitlements, signing, and import inspection

Inspect the exact Developer ID candidate and every nested code object. Record unedited output and compare it with the approved release record:

```sh
/usr/bin/codesign --display --verbose=4 "{{APP_PATH}}"
/usr/bin/codesign --verify --deep --strict --verbose=4 "{{APP_PATH}}"
/usr/bin/codesign -d --entitlements :- "{{APP_PATH}}"
/usr/bin/codesign -d -r- --verbose=4 "{{APP_PATH}}"
/usr/bin/otool -L "{{APP_PATH}}/Contents/MacOS/Token Tank"
/usr/bin/find "{{APP_PATH}}" -type f -print
```

Required findings:

- Developer ID Application identity and Team ID match the release record; designated requirement is captured from the signed app, not invented.
- The embedded Developer ID profile authorizes the exact application identifier used as the data-protection Keychain default group; profile-derived application/team identifiers and any Keychain group contain no extra shared group.
- Hardened Runtime is enabled. App Sandbox is absent for v1, and no JIT, unsigned executable memory, library-validation bypass, broad temporary exception, privileged helper, Automation, or Apple Events entitlement is present.
- `otool -L` and nested bundle inspection show no WebKit/browser runtime, SafariServices, Sparkle/updater framework, update agent, login item, XPC/helper, or privileged installer payload.
- `LSUIElement` remains true; no Dock/browser/updater/helper process is introduced. There is no updater feed, background update check, update key, or automatic replacement path.

| Inspection | Actual output reference | Reviewer result |
| --- | --- | --- |
| Signature identity/flags | `{{CODESIGN_DISPLAY_EVIDENCE}}` | `{{SIGNATURE_RESULT}}` |
| Entitlements | `{{ENTITLEMENTS_EVIDENCE}}` | `{{ENTITLEMENTS_RESULT}}` |
| Designated requirement | `{{DESIGNATED_REQUIREMENT_EVIDENCE}}` | `{{DESIGNATED_REQUIREMENT_RESULT}}` |
| Linked imports/dependencies | `{{IMPORT_EVIDENCE}}` | `{{IMPORT_RESULT}}` |
| Nested payload inventory | `{{PAYLOAD_EVIDENCE}}` | `{{PAYLOAD_RESULT}}` |

## Privacy data-flow record

| Data | In-memory lifetime | Keychain | Preferences/disk | Network destination | Logs/diagnostics | Deletion/quit behavior |
| --- | --- | --- | --- | --- | --- | --- |
| Raw quota values and reset times | process lifetime only | no | no | `{{PROVIDER_DESTINATIONS}}` response only | redacted result class/duration; no raw values | cleared on quit; no snapshot file |
| App-owned credential | transient process use | yes, frozen class | no | injected request only | never | Keychain owner action only |
| External CLI/app owner session | read buffer only | no copy | owner store only | exact accepted source only | never | buffer released after parse |
| Display preferences and stable opaque representative quota ID | UI/process lifetime | no | UserDefaults only; account/source identity components are SHA-256-digested before ID construction | none | no secrets or raw account identifiers | user reset/remove |
| Errors/correlation IDs | in-memory state | no | no raw payload | no secret headers/body | redacted class only | cleared on quit |

`PrivacyInfo.xcprivacy` declares only app-private `UserDefaults` (`CA92.1`). Core no longer directly calls Apple's listed FileTimestamp required-reason APIs: exact owner-path identity is checked against the opened descriptor, the byte cap is enforced with `lseek`, and immutable SQLite reads are bound to that descriptor through `/dev/fd`. Do not add `3B52.1` for the fixed automatic Cursor.app path; it is not a specifically user-granted file. Any future direct required-reason API use must stop release until its implementation and approved reason match.

## AC-11 numeric evidence procedure

Run each of the three independent measurements against the exact process and final regular-file DMG/ZIP artifact:

```sh
/bin/bash Scripts/measure-idle.sh "{{PID}}" "{{EVIDENCE_DIRECTORY}}/run-1" "{{ARTIFACT_PATH}}"
```

Use a new evidence directory for runs 2 and 3. `status=NUMERIC_PASS` means only that all 361 samples, 360 intervals, CPU, maximum RSS, drift, stable-process fingerprint, and artifact-hash gates passed. It is **not** AC-11 sign-off. A reviewer must still match the retained host facts to the frozen physical reference-host requirements and attach proof that all five Providers reached terminal state once under the normal five-minute schedule after warm-up. Notarization and clean-host evidence remain separate release gates.

## Release sign-off checklist

The following checklist is intentionally unresolved until evidence is attached. A checkbox is not a claim that the release passed.

- [ ] All five Provider source rows have an exact source/path/permission/TCC record and complete raw-field inventory.
- [ ] Codex uses only the approved app-server boundary and sends no authentication or mutation method.
- [ ] Claude reads only the Claude Code local usage cache and never presents organization Admin API usage as consumer Pro/Max quota.
- [ ] Grok reads only the Grok CLI owner session plus CLI-proxy credits and never imports cookies, uses grok agent stdio, or calls the xAI Management prepaid-balance API.
- [ ] Cursor reads only the fixed Cursor.app SQLite record with `immutable=1`, persists no token, imports no browser session, and calls only usage-summary.
- [ ] Doubao uses only the approved arkcli usage-plan boundary and never signs OpenAPI requests or copies Volcengine credentials.
- [ ] External-owner immutability tests show no content, metadata, permission, ownership, copy, rotation, or deletion by Token Tank.
- [ ] App credentials use the data-protection Keychain (`kSecUseDataProtectionKeychain`), exact non-synchronizing `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` reads, and app-owned service/account deletion; attribute mismatch or lock/unavailable is stale/no-login and no plaintext fallback exists.
- [ ] No quota snapshot, raw response, session data, or error payload persists on disk; relaunch starts `neverLoaded`.
- [ ] Static Provider I/O audit passes with the exact five-target scope and no suppression.
- [ ] Dynamic opens/network/mutation audit matches the matrix; symlink escape, recursive scan, and write-capable open tests fail closed.
- [ ] Logs, fixtures, archive, exported product, evidence, and CI artifacts contain no secrets or raw account identifiers.
- [ ] Entitlements, signature, designated requirement, imports, nested payloads, and Hardened Runtime match the approved record; App Sandbox and Release coverage instrumentation are absent, the app is stripped, and no user-home build path, browser, updater, or helper exists.
- [ ] TCC/FDA need was either disproven or separately approved with a narrow user-initiated explanation; no SIP/TCC hack, Automation, or Apple Event was used.
- [ ] The manifest declares only required-reason APIs actually used; direct FileTimestamp APIs and the inapplicable `3B52.1` reason remain absent.
- [ ] Distribution evidence is retained: artifact SHA-256, official HTTPS URL, Developer ID, notarization response, staple validation, and clean-host Gatekeeper output.
- [ ] Frozen AC-11 evidence has three independent `NUMERIC_PASS` runs with 361 rows and 360 intervals each, stable-process fingerprints, CPU `< 1.00%`, maximum RSS `< 102400 KiB`, drift gate, reference-host facts, exact artifact facts, and separately reviewed provider terminal-state evidence attached.

Security reviewer: `{{SECURITY_REVIEWER}}`  Signature/date: `{{SECURITY_SIGNOFF}}`

Release owner: `{{RELEASE_OWNER}}`  Decision record: `{{RELEASE_DECISION_RECORD}}`

Until every applicable item has evidence and every Provider-source blocker is explicitly closed, the candidate remains blocked and this document must not be presented as a passed release review.
