# Token Jar security and privacy review

This is a release-gate template. It records required evidence and unresolved questions; it does not claim that a build, Provider, permission, or release passed. Replace `{{PLACEHOLDER}}` only in an external review record. Never put credentials, cookies, raw quota responses, or personal paths in this file.

**Channel scope (2026-09-06):** The current owner-approved distribution channel is
an ad-hoc, unnotarized GitHub prerelease; see the current-channel section of
[Distribution.md](Distribution.md). Developer ID, provisioning, notarization,
clean-host acceptance and full AC sign-off below describe the future stable
channel, not completed prerelease evidence. A prerelease must disclose unperformed
live/hardware checks and must still stop for secret leaks, source/path violations,
unexpected entitlements/payloads, failing verification, or known unsafe behavior.
All five composed adapters use external-provider credentials; app-owned
data-protection Keychain access is not a prerequisite of these sources and is
not promised to work under ad-hoc signing. Never weaken its fail-closed behavior.

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

Complete one row for every source actually used. “Official” applies only to the provider-owned, documented boundary; an undocumented method, endpoint, or storage layout remains explicitly labeled `watch` even when reached through an official client. Organization, team, and billing surfaces retain their real names and never masquerade as consumer quota. CodexBar is reference-only: Token Jar adopts only its preferred Claude OAuth usage path, not its full fallback chain, code, browser-cookie imports, credential caches, usage scraping, local estimates, or unapproved sources. The user separately approved a bounded no-tools Claude Code owner-renewal touch during explicit manual Refresh and Token Jar's narrow Grok OAuth renewal.

| Provider / source kind | Official documentation URL + revision/date | Exact endpoint or canonical path/pattern | Owner that writes/rotates it | Exact files/records and raw fields | Scoped capability/API + mutation flags | Symlink/canonical-containment proof | Permission class / TCC or FDA location | FDA or broad grant required? | User-initiated explanation and pane | Denial/revocation behavior | Before/after mutation evidence | Reviewer/status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Codex / official app-server | `https://developers.openai.com/codex/app-server/` / `{{CODEX_DOC_REVISION}}` | `account/rateLimits/read` and optional `account/read` with `refreshToken: false` over separate allowlisted `codex app-server` stdio processes for `~/.codex` and optional `~/.codex-secondary` | Codex CLI owns and rotates each native session | every keyed primary/secondary `usedPercent`, exact arithmetic complement, duration/reset, balance credit, reset-credit record, and optional account email; account source identity keeps failures and snapshots independent | narrow size/time-bounded Core `CodexAccountUsageReader`; fixed secondary file-store override; no auth mutation methods or credential opens | allowlisted executable candidates and fixed home directories only | none identified | no | terminal login instructions in Distribution.md | missing secondary directory omitted; individual source failure retains only that source's stale data; optional identity failure never substitutes another account | both native homes returned distinct ChatGPT emails and successful usage on 2026-09-05; final application-candidate rerun separate | **SOURCE ACCEPTED — two native sources validated** |
| Claude / unofficial Claude Code OAuth source | CodexBar preferred OAuth path / current reference | fixed OAuth usage/profile GETs; `claudeAiOauth` in exact native file or generic-password Keychain service `Claude Code-credentials` plus `kSecAttrAccount=NSUserName()` | Claude Code owns/may rotate stores | finite-positive-expiry `user:profile` AI OAuth only; MCP forbidden | absent AI may try the exact service-and-account Keychain item; present invalid AI cannot; expiry after reads | exact allowlists | no TCC/FDA | no broad grant | background 5 s no-prompt; manual 120 s may await human password/biometric approval; timeout does not prove denial | bounded/serialized; timeout/cancel late data discarded | owner PTY uses valid empty MCP schema, canonical `NSUserName()` for `USER`/`LOGNAME`, ANSI CSI normalization, two exact trust questions, unknown-prompt denial, and no secret/raw-output logging | **WATCH — exact-account live HTTP 200, official interactive re-login, frozen v4 manual usage, and same-binary background cold start verified; natural-expiry changed-token renewal pending** |
| Grok / Grok CLI SuperGrok credits and narrow OAuth renewal | `https://auth.x.ai/.well-known/openid-configuration` and `https://github.com/steipete/CodexBar/blob/main/docs/grok.md` / current | selected OIDC entry in `~/.grok/auth.json`; fixed `POST https://auth.x.ai/oauth2/token` when expiry is within 60 seconds or the first primary request returns 401/403; primary `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`; only when a successful proxy response leaves usage unknown, `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` | Grok CLI owns the store; Token Jar may renew and atomically preserve only the selected OIDC entry | selected access token, refresh token, `expires_at`, non-empty `oidc_client_id`, exact `https://auth.x.ai` issuer/client-scope identity, and optional email; primary published `creditUsagePercent` or same-row on-demand used/cap ratio, plus proxy reset/source metadata and account identity; unchanged fallback interpretation | Grok-scoped Core session capability reads and, only after a successful official public-client refresh grant, replaces the same file through a same-directory mode-0600 temporary file; fixed token endpoint has no redirects or cookies; proxy and conditional billing requests remain injected HTTPS with one post-renewal proxy retry | canonical owner path; no recursive discovery; a bounded Token-Jar-only lock spans current-file reread, HTTP rotation, comparison, and persistence; observable newer external session wins | none identified | no | no System Settings request | missing or revoked refresh credentials request `grok login`; network and other transient errors remain stale and are not reclassified as revocation; failed/unrecognized billing fallback retains unknown usage and proxy metadata | 2026-09-11 token-safe current-host production-provider probe forced one renewal and verified rotated access/refresh tokens, matching persisted session, future expiry, mode 0600, preserved noncredential metadata, successful real-adapter usage with one percentage-bearing quota, and matching account identity; no secrets printed/copied. Earlier 117 package and 33 app-unit results predate the final changes; the latest full package suite passed 168 tests in 12 suites, while the app rerun is pending. Thirteen release-tool tests, Provider I/O and FileTimestamp checks, independent integration review, and rotation review pass 2 passed in the earlier run. Not proven: natural expiry, real HTTP 401/403 injection, concurrent real CLI rotation, packaged release, other OS, CI/notarization; the lock is not CLI-honored and cannot close the uncooperative CLI final-rename window | **WATCH — renewal/rotation/usage verified on current host; remaining final-candidate gates pending** |
| Cursor / immutable Cursor.app owner session | Cursor usage/limits docs and CodexBar Cursor reference / `{{CURSOR_DOC_REVISION}}` | `ItemTable[cursorAuth/accessToken, cursorAuth/cachedEmail]` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` opened with `immutable=1`, then `GET https://cursor.com/api/usage-summary` | Cursor.app owns and rotates the JWT | billing cycle/type flags; individual and team quota blocks, plan breakdowns, source percentages, and optional cached email | exact immutable SQLite capability plus exact HTTPS destination; token validation and endpoint authentication unchanged; email is display-only | canonical owner path opened with `O_NOFOLLOW`, descriptor-bound immutable SQLite, fixed DB/table/two-key query, ordinary-table and duplicate-row rejection | current host immutable open succeeded without TCC; final actual-open proof required | no broad grant observed; manifest declares only UserDefaults | no System Settings request | missing/expired/rejected session requests source-owner login; I/O/schema failure remains stale; absent/invalid email text is omitted | live main/WAL/SHM facts unchanged under immutable read; email and final frozen rerun pending | **WATCH — live usage shape validated; layout/endpoint undocumented** |
|| Doubao / official arkcli plan usage | `https://github.com/volcengine/ark-cli` / current | `arkcli usage plan --format json` over the allowlisted arkcli executable | arkcli owns and rotates SSO | every Coding/Agent plan window and source used/total/remaining/percentage/reset field; exact same-row remaining/percentage arithmetic only when omitted | narrow size/time-bounded Core `DoubaoPlanUsageReader`; no auth mutation methods | allowlisted executable candidates only | none identified | no | not applicable | missing executable/session requests `arkcli auth login`; generic CLI failure remains stale | no mutation | **WATCH — official arkcli plan usage; never OpenAPI AK/SK** |

### Accepted source decision and remaining live gates

The unofficial WATCH Claude source accepts only `claudeAiOauth`. A valid file record is authoritative; an absent AI record, including a valid MCP-only file, may try only the generic-password service `Claude Code-credentials` with `kSecAttrAccount=NSUserName()`. Service-only lookup selected a different OS account during QA, so it is forbidden. A present malformed, wrong-scope, or invalid-expiry AI record cannot fall back. MCP tokens are never used or renewed, and MCP-only in both stores maps to missing/source-login. Expiry is evaluated after potentially slow reads. Locked/off-console collection skips Keychain. Other native queries use one bounded utility worker per reader (background 5 s, manual 120 s to allow human password or biometric entry), reject overlap while a timed-out call remains unresolved, and discard late results after timeout or cancellation. A timeout means only that no result arrived within the bound; it does not establish approval denial. `ClaudeNativeKeychainAccess` serializes process-wide calls; background access temporarily disables process-local Keychain interaction and always restores its previous value. It never changes an item ACL or user Keychain setting, and manual mode never enables a previously disabled inherited policy.

Historical evidence remains scoped to its date: on 2026-09-07, the production Swift adapter and network capability recovered used 0% and remaining 100% from a validated active-period proto3 implicit zero after a period-only proxy response, and all 97 package tests passed for that pre-renewal implementation. Earlier live probing rejected the Grok ACP `x.ai/billing` path because official Grok 1.0.13 returned JSON-RPC -32601.

Current evidence is scoped, not release sign-off. The old Core sanitized environment omitted `USER` and `LOGNAME`, while the production owner `safeEnvironment` now derives both from `NSUserName()`; the fixed production `/status` touch completed in about 1.28 seconds. That status touch does not establish automatic rotation of a naturally expired token. Native metadata QA separately found that a service-only Keychain query selected another OS account, so production now also pins `kSecAttrAccount=NSUserName()`; 27 native-session tests passed. The correct account's token could be read, but live API calls with User-Agent versions 2.1.0 and 2.1.234 both returned 401 `authentication_error` with a revoked indication. This was actual provider authentication failure, not missing native approval. The user explicitly authorized official `claude --safe-mode auth login --claudeai`; it exited 0 after browser approval. An exact-account direct OAuth usage GET then returned 200 with numeric `five_hour` and `seven_day` utilization, reset strings, limits, and `extra_usage` present. Frozen dirty-source local-v4 manual Refresh showed fresh Claude usage percentage and account label. Restarting the same approved binary produced a fresh background cold start with usage and account and no native prompt observed. The plan UI is not verified because its accessibility identifier was absent. No raw bodies, values, tokens, or account identifiers were retained here. The latest full package suite passed 168 tests in 12 suites, all 27 native tests passed, the post-fix app suite passed 35 tests, the post-fix full UI suite passed 19 tests, and the universal Release build succeeded. `/tmp/token-jar-0.1.10-localqa-v4/TokenJar-0.1.10.zip` packaged successfully with SHA-256 `d8b1c4512975c2843971e463ce13f28674deaf45327b47609434c1fe4849a167`. Independent verification confirmed the v4 feed and archive Ed25519 signatures, archive length and SHA-256, and graceful app termination. Local-v1 through local-v3 are obsolete, and no dirty-source QA package may be published. Natural-expiry changed-token renewal, real old-to-new upgrade, physical Intel, clean/quarantined host, final clean revision, signing, and publication remain unverified.

For v0.1.10 on 2026-09-11, the user explicitly accepted prerelease publication with natural-expiry changed-token renewal, real upgrade, physical Intel, and clean/quarantined-host checks disclosed as unverified. This does not waive failed tests, security or payload audits, clean-revision packaging, signed update verification, or remote publication gates. The QA evidence above is not a claim that those manual checks passed.

## Ownership and immutability contract

- Token Jar accepts only Claude AI OAuth credentials, never MCP tokens. It neither changes Claude credentials nor item ACLs/user Keychain settings. Claude Code may mutate its own AI OAuth store during approved manual owner renewal.
- Token Jar may write app-owned generic-password Keychain items through the Core credential capability. The sole direct external-owner-store mutation by Token Jar is the user-approved Grok renewal: after a successful official grant, it may atomically replace only `~/.grok/auth.json` through a same-directory mode-0600 temporary file, without backups or another secret store.
- Other external CLI/browser stores remain immutable to Token Jar. For Grok, a bounded token-free coordination lock shared only by Token Jar processes spans the current-file reread, HTTP rotation, conflict comparison, and same-file persistence. Comparison detects observable CLI rotation and prefers a newer session, but cannot close the final rename window against an uncooperative concurrent Grok CLI writer.
- External reads use source-specific capabilities with canonical containment, no recursive discovery, and no unreviewed symlink or Keychain-service scan. Write-capable operations and metadata/content mutation are forbidden except for the reviewed Grok replacement. Provider code cannot instantiate filesystem, network, Security, process, WebKit, or browser APIs.

| Check | Fixture/path identifier | Before facts | Read operation | After facts | Expected result | Evidence / status |
| --- | --- | --- | --- | --- | --- | --- |
| Owner writes fixture | `{{FIXTURE_ID}}` | `{{BEFORE_FACTS}}` | owner-controlled update only | `{{AFTER_OWNER_UPDATE}}` | change belongs to owner | `{{OWNER_UPDATE_EVIDENCE}}` |
| Token Jar read | `{{FIXTURE_ID}}` | `{{BEFORE_FACTS}}` | `{{READ_CAPABILITY}}` with read-only mode | `{{AFTER_READ_FACTS}}` | bytes/metadata unchanged | `{{READ_IMMUTABILITY_EVIDENCE}}` |
| Missing/removed source | `{{FIXTURE_ID}}` | `{{PRESENT_FACTS}}` | source removed by owner | `{{MISSING_FACTS}}` | typed external-session-missing; no login unless contract says so | `{{MISSING_SOURCE_EVIDENCE}}` |
| Unsafe symlink/path escape | `{{SYMLINK_FIXTURE_ID}}` | `{{LINK_FACTS}}` | canonicalization attempt | `{{DENIAL_FACTS}}` | permission/path-unsafe; no follow or fallback scan | `{{SYMLINK_EVIDENCE}}` |

## App credentials and Keychain class

The external `Claude Code-credentials` item is read-only to Token Jar and is queried only with `kSecAttrAccount=NSUserName()`; service-only lookup is forbidden because it selected another OS account during QA. Native blocking calls use one bounded utility worker per reader plus process-wide serialization. Locked/off-console paths skip them. Background access calls `SecKeychainGet/SetUserInteractionAllowed(false)` for process-local scope and always restores the prior policy on success/error; manual access never enables an inherited-disabled policy. Neither mode modifies ACLs or user Keychain settings. Deprecated Keychain APIs and UI Allow/Fail query flags remain intentionally combined with `LAContext` for legacy no-prompt compatibility; do not claim warning-free compilation.

| Case | Required behavior | Evidence |
| --- | --- | --- |
| Normal post-first-unlock read | Read only the app-owned item through Core; do not expose its value to diagnostics or Provider source code. | `{{KEYCHAIN_NORMAL_EVIDENCE}}` |
| Native Claude query | exact service-and-`NSUserName()` account lookup; locked/off-console skips; otherwise one reader worker, background 5 s/manual 120 s; no replacement while timed-out call unresolved; timeout/cancel discards late data; timeout alone does not prove approval denial | exact-account read succeeded; revoked-token live 401 was provider authentication failure, not missing native approval; official interactive re-login and subsequent live/manual/background usage recovery verified |
| Explicit Provider rejection/revocation | Show the app-owned login action only when the Provider contract identifies rejection/revocation. | `{{KEYCHAIN_REVOKED_EVIDENCE}}` |
| Item deleted by the user | Show app credential setup; never conflate deletion with a temporary lock and never use a plaintext fallback. | `{{KEYCHAIN_DELETED_EVIDENCE}}` |
| Device migration/restore | `ThisDeviceOnly` item does not migrate; require setup on the new device. | `{{KEYCHAIN_MIGRATION_EVIDENCE}}` |

## Snapshot and persistence review

Provider snapshots, raw quota values/responses, reset times, error payloads, copied session data, correlation payloads, and last-known-good values are memory-only for v1. Relaunch begins `neverLoaded`; quitting clears snapshots. Token Jar creates no Claude credential or usage cache. External native Claude stores remain Claude Code-owned, and the only direct provider-session persistence by Token Jar is the reviewed Grok same-owner-file renewal. Only non-secret display preferences may persist in `UserDefaults`.

| Storage surface | Allowed data | Forbidden data | Check/evidence |
| --- | --- | --- | --- |
| Keychain | App-owned credentials; read-only exact `Claude Code-credentials` AI OAuth access | MCP token acceptance/renewal, copies, ACL changes, user-setting changes, raw responses/snapshots | `{{KEYCHAIN_STORE_SCAN}}` |
| UserDefaults/preferences | Non-secret display settings only | Credentials, snapshot, raw response, errors, session data | `{{PREFERENCES_SCAN}}` |
| Files/cache/temp | Read-only native `~/.claude/.credentials.json`; Claude runner's empty mode-0700 temporary workdir removed after bounded cleanup; Grok same-directory mode-0600 renewal temporary file removed by replacement/cleanup | Claude credentials, snapshots, raw TUI/output, or other auth data in its workdir; copied response/error/session data; legacy Claude cache fallback; Grok backup/other store | `{{FILES_CACHE_SCAN}}` |
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

- Filesystem: allow exact read-only provider paths, Claude's empty mode-0700 temporary workdir removed after bounded cleanup, and the Grok mode-0600 atomic-replacement temporary file. The Claude workdir must contain no credential, snapshot, response, error, or raw TUI persistence. Do not scan a home directory.
- Network: record the injected request destination, method, header classes without values, timeout, cancellation, status, and body size. Claude is limited to OAuth `GET /api/oauth/usage` and optional same-token `GET /api/oauth/profile` at `api.anthropic.com`; no inference or Admin API request. Provider-created networking remains forbidden.
- Keychain: accept only `claudeAiOauth`; MCP tokens are forbidden. Query native Claude credentials only by exact service plus `kSecAttrAccount=NSUserName()`; never use service-only matching or another same-service account. Use one bounded worker per reader and process-wide serialized native access. Background temporarily sets process-local interaction false and restores it on every exit; manual never enables inherited-disabled interaction. Do not overlap unresolved timeouts, accept late results, change ACLs/user settings, or broaden lookup. Deprecated legacy controls remain intentional.
- Process/browser/automation: only explicit manual Refresh after expiry may use the allowlisted Claude executable with exact `--safe-mode --tools '' --allowed-tools '' --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}'`, dedicated process group, empty mode-0700 workdir, 15-second/256-KiB bounds, and cleanup. Its safe environment supplies `USER` and `LOGNAME` from the same canonical `NSUserName()` value and does not inherit arbitrary environment variables. Strip ANSI CSI layout before exact readiness, trust, and status matching. Accept only `Is this a project you created or one you trust?` and the reviewed older exact empty-workspace question; deny unknown prompts. Send only `/status` plus cancel/exit. Never log tokens or persist raw output.
- Mutation: hash and stat reviewed fixtures before and after. Claude stores must remain unchanged by Token Jar; in manual recovery Claude Code may change its own store, after which Token Jar must prove the token is changed and fresh. The only direct external-store mutation by Token Jar is the reviewed Grok selected-field atomic replacement; no backup or other secret-store entry may appear.

| Dynamic scenario | Observed opens/destinations | Mutation/ownership result | Error mapping | Evidence |
| --- | --- | --- | --- | --- |
| Fresh success | `{{SUCCESS_OPERATIONS}}` | `{{SUCCESS_IMMUTABILITY}}` | none | `{{SUCCESS_DYNAMIC_EVIDENCE}}` |
| External owner atomic replacement | `{{OWNER_REPLACEMENT_OPERATIONS}}` | re-read new owner version; no Token Jar lock/copy/write | `{{OWNER_REPLACEMENT_ERROR}}` | `{{OWNER_REPLACEMENT_EVIDENCE}}` |
| Claude native/manual access | exact service-and-`NSUserName()` account lookup; background 5 s/no popup; manual 120 s/may await password or biometric approval; timeout/cancel late results are discarded and timeout does not prove denial; owner PTY has canonical `NSUserName()` identity, valid empty MCP schema, ANSI normalization, exact-prompt allowlist, unknown-prompt denial, and no raw/token logging | exact-account revoked-token 401 mapped to authentication failure; the user-authorized official interactive re-login exited 0 after browser approval; Token Jar did not directly mutate the owner store | direct live usage GET 200 plus frozen v4 manual fresh usage/account and same-binary background cold-start fresh usage/account with no native prompt observed; post-fix app 35 and full UI 19 passed; natural-expiry changed-token renewal and plan UI remain unverified |
| Grok successful renewal | `{{GROK_RENEWAL_OPERATIONS}}` | bounded Token-Jar-only lock spans reread, HTTP rotation, comparison, and selected-field-only same-file atomic replacement through mode-0600 temporary file; no backup/other store | newer observable external session wins; started shared transaction settles before canceled observer receives `CancellationError`; pre-start cancellation aborts | 2026-09-11 token-safe production-provider live probe and current rotation/integration review; natural expiry, real HTTP 401/403, and concurrent real CLI rotation pending |
| Offline/timeout/429 | `{{NETWORK_FAILURE_OPERATIONS}}` | no local mutation | stale/retry; no login | `{{NETWORK_FAILURE_EVIDENCE}}` |
| Permission denial/TCC revoke | `{{PERMISSION_OPERATIONS}}` | no fallback scan or workaround | permissionDenied/stale; frozen System Settings action | `{{PERMISSION_EVIDENCE}}` |
| Malformed/schema change | `{{SCHEMA_OPERATIONS}}` | no snapshot persistence | data-format/schema stale | `{{SCHEMA_EVIDENCE}}` |

## TCC/FDA permission stop gate

Discovery that a required source is TCC-protected, needs Full Disk Access, needs Files and Folders consent, or needs a similarly broad user grant **stops the affected Provider lane for separate explicit consensus**. It is not routine onboarding and is not waived by a successful local test. The reviewer must record exact location, minimum grant, user explanation, denial behavior, and why no narrower source exists before any approval.

- The request, if approved, is initiated by the user from the affected Provider setup/recovery surface and names the Provider, exact read-only quota purpose, and System Settings pane.
- Denial, revocation, or an unavailable permission maps to `permissionDenied`/stale, preserves the in-memory value, retries only on the next cycle or explicit retry, and never prompts login or silently skips the Provider.
- Token Jar never changes permissions or ownership and never edits, resets, disables, or bypasses TCC or SIP. Do not use `tccutil reset`, modify the TCC database, disable SIP, inject entitlements, grant Terminal-wide access, or instruct the user to weaken system protections.
- Browser automation, cookie import, PTY usage scraping, arbitrary interactive CLI driving, and Apple Events are forbidden. The sole Claude PTY exception is the user-approved fixed no-tools owner-renewal touch during explicit manual Refresh; it never supplies usage data. The approved Codex app-server boundary is provider-documented JSON-RPC, not UI automation.

| Provider | Exact protected location | Minimum requested permission | Why narrower read is impossible | User explanation/pane | Denial/revocation | Consensus decision |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | allowlisted CLI executable only; Token Jar does not open the Codex credential store | none | official app-server owns credential access | no System Settings request | missing/revoked owner session requests Codex login; generic failure stays stale | no TCC/FDA grant approved |
| Claude | exact file/service/OAuth/executable | none | lock skips; background process-local interaction disabled/restored; manual may request native approval and owner CLI may rotate AI OAuth | native prompt appears only on explicit Refresh; all current user approvals confirmed; no broad grant | background unavailable/retry; manual 120 s bound with timeout/cancel late discard; timeout does not prove denial; MCP-only missing/source-login; malformed AI no fallback | no ACL/user-setting mutation; WATCH |
| Grok | `~/.grok/auth.json`; `auth.x.ai/oauth2/token`; primary `cli-chat-proxy.grok.com/v1/billing?format=credits`; conditional `grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` | none | Grok CLI owns the store; Token Jar may perform only the reviewed OIDC refresh and atomic same-file preservation, then uses the proxy primary and unchanged same-session billing fallback | no System Settings request | missing/revoked refresh credentials request `grok login`; network errors remain transient; after first proxy 401/403 renew and retry once; unknown proxy usage and failed/unrecognized fallback remain unknown with proxy metadata preserved | no TCC/FDA grant required |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` and active SQLite sidecars | none observed; final candidate actual-open proof pending | immutable fixed-record read avoids browser stores and SQLite lock/SHM mutation | no System Settings request | permission denial remains stale and stops the lane; no fallback or broad prompt | no broad grant approved; current-host immutable open succeeded |
|| Doubao | allowlisted arkcli executable only; Token Jar does not open the Volcengine credential store | none | official arkcli owns credential access | no System Settings request | missing/revoked owner session requests `arkcli auth login`; generic failure stays stale | no TCC/FDA grant required |

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
/usr/bin/otool -L "{{APP_PATH}}/Contents/MacOS/Token Jar"
/usr/bin/find "{{APP_PATH}}" -type f -print
```

Required findings:

- Developer ID Application identity and Team ID match the release record; designated requirement is captured from the signed app, not invented.
- The embedded Developer ID profile authorizes the exact application identifier used as the data-protection Keychain default group; profile-derived application/team identifiers and any Keychain group contain no extra shared group.
- Hardened Runtime remains enabled. The user approved only `com.apple.security.cs.disable-library-validation=true` for ad-hoc hosts to load Sparkle without a Team ID. App Sandbox, JIT, unsigned executable memory, Automation, Apple Events, and broad temporary exceptions remain absent. Re-enable library validation for Developer ID distribution.
- Only pinned Sparkle 2.9.6 and its exact framework/Autoupdate/Updater.app/distributed XPC inventory are approved. Lookalike or extra payloads are rejected. WebKit references are vendor-only; `SUShowReleaseNotes=false` disables HTML release-note UI.
- `LSUIElement` remains true. No login item or embedded browser is added. Sparkle's audited installer/relaunch processes may run during user-approved updates; the application delegate finishes provider shutdown before relaunch.

### Native signed-update threat model

Sparkle replaces the JSON checker entirely: scheduling, preferences, download,
verification, installation and relaunch are vendor-managed. Provider capabilities
are unchanged; no shell installer or parallel notification checker remains.

| Threat | Required control |
| --- | --- |
| Feed compromise | HTTPS signed appcast, pinned `SUPublicEDKey`, `SURequireSignedFeed=true`, `SUSignedFeedFailureExpirationInterval=0`; invalid metadata fails closed indefinitely |
| Corrupt/substituted archive | Ed25519 signature and `SUVerifyUpdateBeforeExtraction=true`, then Sparkle's installation checks |
| Unreviewed executable | Exact pinned vendor inventory, strict signatures, host/dependency import and payload gates; no blanket helper allowance |
| Signing-key theft/loss | Operator login Keychain account `token-jar-updates`; no private-key export/logging/publication; secure Keychain backup; key loss requires a manually installed new trust root |
| Silent install | Automatic checks can be disabled; `SUAllowsAutomaticUpdates=false` and `SUAutomaticallyUpdate=false`; native update approval required |
| Provider data leakage | No account/usage/credentials passed to Sparkle; system profiling and release notes disabled |
| Shutdown race | Preserve asynchronous AppModel termination before replacement/relaunch |
| Bad signed release | Retain prior verified app/assets/feed; test old-to-new installation; publish assets before feed; monotonic build numbers and manual rollback |
| Library injection risk | Approved host-only library-validation exception, all other Hardened Runtime protections retained, exact entitlement dictionary audited; remove exception when Developer ID becomes available |

The fixed feed is
`https://raw.githubusercontent.com/nahwan-kim/token-jar/main/appcast.xml`.
Packaging generates versioned archive URLs in this repository's GitHub Releases.
GitHub/CDN receives ordinary HTTP connection metadata including IP address.
Sparkle may follow hosting redirects; cryptographic validation, not a zero-redirect
claim, is the update trust boundary. Its app-private preferences, cache and
staging files contain update material, not provider snapshots.

Ad-hoc signing is not Apple publisher verification. EdDSA authenticates continuity
from the public key embedded at first manual installation, not the initial
download's provenance. Gatekeeper, quarantine, translocation, read-only locations,
and authorization remain ordinary macOS gates. Never remove quarantine or disable
Gatekeeper/SIP to make tests pass. Versions through 0.1.3 need manual bootstrap.

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
| Optional account email | snapshot/process lifetime; compact provider header and full tooltip/accessibility text | no | no | same provider-owned source only | never | cleared on quit; stale snapshots retain only their own email |
| App-owned credential | transient process use | yes, frozen class | no | injected request only | never | Keychain owner action only |
| External CLI/app owner session | read buffer only, except transient Grok renewal values | no copy or cache | owner store only; Grok may atomically update the same `~/.grok/auth.json` selected entry after successful renewal | exact accepted source and Grok token endpoint only | never | buffer released after parse; persisted Grok rotation remains owner-session material |
| Display preferences and stable opaque representative quota ID | UI/process lifetime | no | UserDefaults only; account/source identity components are SHA-256-digested before ID construction | none | no secrets or raw account identifiers | user reset/remove |
| Errors/correlation IDs | in-memory state | no | no raw payload | no secret headers/body | redacted class only | cleared on quit |
| Update feed/archive | Sparkle operation lifetime | release signing key only on operator machine, never client | Sparkle preferences/cache/staging | signed GitHub feed and versioned GitHub/CDN archive | Sparkle update status, no provider data | Sparkle-managed cleanup |

The host `PrivacyInfo.xcprivacy` declares app-private `UserDefaults` (`CA92.1`). Host/Core direct FileTimestamp imports remain prohibited. The pinned Sparkle 2.9.6 payload does not ship a separate privacy manifest; updater-only filesystem imports are an explicit vendor exception, not evidence of App Store privacy compliance. A future App Store/privacy submission requires a separate review of Sparkle's actual required-reason API uses and declarations. Do not add `3B52.1` for the automatic Cursor.app path or copy an unrelated SDK's reason.

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
- [ ] Claude accepts only `claudeAiOauth`; absent AI may try only Keychain service `Claude Code-credentials` plus `kSecAttrAccount=NSUserName()`, present invalid AI may not fall back, MCP is never used/renewed, both-store MCP-only maps missing/source-login, and expiry is checked after slow reads.
- [ ] Grok uses only the selected Grok CLI OIDC session and approved official renewal when expiry is within 60 seconds or the first proxy request returns 401/403; it atomically preserves only the new access token, expiry, and optional rotated refresh token in the same file, then retries the primary proxy once. The bounded Token-Jar-only lock spans reread, HTTP rotation, comparison, and persistence; a started shared transaction settles despite observer cancellation, while pre-start cancellation aborts. The unchanged same-session, no-cookie, 6-second billing fallback runs only after a successful proxy response with unknown usage and preserves proxy reset/source metadata. No cookies, Grok ACP stdio, CLI subprocess, manual-token UI, local estimates, xAI Management API, Keychain token cache, backup, or other secret store is allowed.
- [ ] Cursor reads only the fixed Cursor.app SQLite record with `immutable=1`, persists no token, imports no browser session, and calls only usage-summary.
- [ ] Doubao uses only the approved arkcli usage-plan boundary and never signs OpenAPI requests or copies Volcengine credentials.
- [ ] Native Keychain calls remain bounded/serialized at 5 seconds in background and 120 seconds manually, with timeout/cancel late discard and restored process-local interaction policy; timeout alone is not denial evidence. Exact-account read and the same approved v4 binary's no-prompt background cold start are confirmed.
- [ ] Owner PTY uses canonical `NSUserName()` values for `USER`/`LOGNAME`, `{"mcpServers":{}}`, ANSI CSI normalization, both reviewed exact empty-workspace questions, unknown-prompt denial, and no raw-output/token logging. The fixed production `/status` touch completed in about 1.28 seconds but does not prove natural-expiry renewal. The revoked-token 401 was provider authentication failure, not missing native approval; official interactive re-login and subsequent live HTTP 200 usage recovery are verified, while natural-expiry changed-token renewal remains pending.
- [ ] No quota snapshot, raw response, copied session data, or error payload persists on disk; relaunch starts `neverLoaded`. Token Jar creates no Claude credential or usage cache; its sole direct provider-session persistence is the reviewed Grok same-owner-file token rotation.
- [ ] Static Provider I/O audit passes with the exact five-target scope and no suppression.
- [ ] Dynamic opens/network/process/mutation audit matches the matrix; Claude exact paths, headers, no-prompt automatic mode, fixed no-tools manual owner touch, changed-token enforcement, and forbidden fallbacks are recorded, while symlink escape, recursive scan, unreviewed operations, and writes fail closed.
- [ ] Logs, fixtures, archive, exported product, evidence, and CI artifacts contain no secrets or raw account identifiers.
- [ ] Entitlements, signature, designated requirement, imports, nested payloads, and Hardened Runtime match the approved record; App Sandbox and Release coverage instrumentation are absent, the app is stripped, and no user-home build path, browser, updater, or helper exists.
- [ ] TCC/FDA need was either disproven or separately approved with a narrow user-initiated explanation; no SIP/TCC hack, Automation, or Apple Event was used.
- [ ] The manifest declares only required-reason APIs actually used; direct FileTimestamp APIs and the inapplicable `3B52.1` reason remain absent.
- [ ] Distribution evidence is retained: artifact SHA-256, official HTTPS URL, Developer ID, notarization response, staple validation, and clean-host Gatekeeper output.
- [ ] Frozen AC-11 evidence has three independent `NUMERIC_PASS` runs with 361 rows and 360 intervals each, stable-process fingerprints, CPU `< 1.00%`, maximum RSS `< 102400 KiB`, drift gate, reference-host facts, exact artifact facts, and separately reviewed provider terminal-state evidence attached.

Security reviewer: `{{SECURITY_REVIEWER}}`  Signature/date: `{{SECURITY_SIGNOFF}}`

Release owner: `{{RELEASE_OWNER}}`  Decision record: `{{RELEASE_DECISION_RECORD}}`

Until every applicable item has evidence and every Provider-source blocker is explicitly closed, the candidate remains blocked and this document must not be presented as a passed release review.
