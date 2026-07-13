## 2026-07-13 - Bridgeport 1.0.6 public-readiness hardening

**What changed**: Replaced maintainer-specific new-install paths and Cloudflare identity defaults with neutral user-owned locations and blank identity fields while preserving explicit existing configuration. Redacted private deployment examples from the current documentation tree. Added CI, a release gate, full-history Gitleaks scanning, a clean-install verifier, corrected DMG staging, release documentation, privacy and security policies, and a threat model.

**Verification**: `swift test` passed all 44 tests. `python3 test_client.py` passed all 12 HTTP smoke checks. `swift build -c release`, `script/build_and_run.sh --verify`, source-built app assembly, and isolated clean-install verification passed. Gitleaks scanned all 23 commits with zero unignored findings. `Bridgeport-1.0.6.dmg` was Developer ID signed, accepted by Apple's notary service, stapled, accepted by Gatekeeper, and passed the notarized clean-install verifier. Its SHA-256 is `12b3b534d5961860d36caca1221022656e9444b4bb9d730f810badcbd088b60b`.

**Public-release gate**: The repository remains private and all rights reserved. Select a source license before changing visibility, then decide whether the maintainer paths and private deployment hostname retained in older commits warrant a history rewrite or a fresh public repository.

---

## 2026-07-08 - Mac App Store readiness audit

**What changed**: No source files changed. Audited Bridgeport's Mac App Store submission readiness against the current direct-distribution path. Confirmed the existing release flow is a Developer ID Application signed, notarized DMG flow, not a Mac App Store packaging/upload flow.

**Decisions made**: Direct notarized DMG distribution remains the viable channel right now. A Mac App Store submission would need a separate store-safe variant or a major architecture pass because the current app is unsandboxed, has no entitlements/provisioning/store metadata, installs LaunchAgents, spawns local MCP connector processes, reads user config locations such as `.claude`, `.codex`, and `.config`, and shells out to tools such as `cloudflared` and `op`. Notarization and Gatekeeper acceptance are not the same as Mac App Store readiness.

**Left off at**: Verification during the audit passed: `swift test` passed 43 tests, `python3 test_client.py` completed all smoke checks successfully, `swift build -c release` passed, and the existing `dist/release/Bridgeport.app` plus `Bridgeport-1.0.2.dmg` verify as signed/notarized Developer ID artifacts. The repo was clean before this worklog entry.

**Open questions**: Decide whether Bridgeport should remain direct-distribution only, or whether to build a Mac App Store variant. If pursuing the store path, next work is App Sandbox entitlements, a store-safe helper/login-item model, user-selected/bookmarked file access for connector sources, an App Store Connect app/profile/signing path, release Xcode build tooling, store screenshots, and privacy metadata.

---

## 2026-07-05 - Bridgeport 1.0.5 speed, security, and setup-UX pass

**What changed**: Full-codebase review pass covering speed, reliability, security, the icon system, and Apple HIG conformance for the settings UI. Serving-path speed: connector discovery is cached for 2 seconds so MCP requests stop re-walking the filesystem, and icon decoration skips the JSON round-trip for messages without `serverInfo`. Reliability: live sessions are capped at 64 with `503`/`Retry-After` beyond that, and all `launchctl` calls in the menu bar app moved off the main thread so daemon restarts no longer freeze the window. Security: OAuth token/registration responses are `no-store`, failed approval-page token attempts are delayed 1s, and streamable responses expose `Mcp-Session-Id` to browser clients. Icon system: `/icons/<connector>` now follows MCP route exposure rules (local for enabled connectors, public hostname only for Public-toggled ones), private connectors advertise localhost icon URLs in `initialize`, the endpoint supports `ETag`/`304`, `HEAD` uses file metadata instead of reading the file, and discovery covers `logo.*` and repo-root icon filenames. UX: new per-provider **Step-by-Step Setup** guide with copy buttons on each Cloud Connectors card (Claude, ChatGPT/Codex, Mistral), "Copied" feedback on every copy button, a two-way query-token toggle in Cloud Connectors, proper ellipsis characters, "Choose…" open panels with messages/prompts, aligned window minimum size, and the `op://` reference field is a plain text field.

**Verification**: Authored on a Linux container without a macOS toolchain: all Swift sources pass `swiftc -parse` under Swift 6.2, FlyingFox 0.26.2 API usage (`.notModified`, `.serviceUnavailable`) verified against the pinned source, and 3 new unit tests cover the icon fast path, discovery caching, and icon candidate ordering. Run `swift test`, `python3 test_client.py`, and `script/build_and_run.sh --verify` on the Mac before packaging `v1.0.5`.

**Left off at**: Source changes and docs updated for a `v1.0.5` release; `docs/release-notes/v1.0.5.md` is in place, so dispatching the Release workflow (or pushing a `v1.0.5` tag) publishes the release. DMG packaging/notarization still happens on the Mac.

---

## 2026-07-02 - Bridgeport 1.0.3 reliability and robustness pass

**What changed**: Comprehensive reliability review of the daemon's serving path. SSE/streamable HTTP responses now stream chunked byte buffers instead of one byte at a time, sessions track activity and an idle reaper closes abandoned sessions so disconnected clients no longer leak connector subprocesses, `Mcp-Session-Id` values are scoped to the connector that issued them (including DELETE), OAuth access tokens persist across daemon restarts so connected Claude custom connectors survive settings saves without re-authorizing, the OAuth client registry is capped at 256 entries, connector stdin writes moved off the cooperative executor onto a serial queue, connector shutdown now closes stdin and escalates SIGTERM to SIGKILL after a 5s grace period, connector stdout lines are capped at 32 MB, `runShell` drains stderr concurrently to remove a pipe-buffer deadlock, and the cloudflared tunnel lookup no longer misreads Go zero timestamps in `deleted_at` as deletions. Added a tag-push GitHub Actions workflow that publishes releases from annotated tags.

**Verification**: Authored on a Linux CI container without a macOS toolchain: all Swift sources pass `swiftc -parse` syntax checking, and the changes ship with 5 new unit tests plus a new `test_client.py` smoke test (streamable HTTP session DELETE). Run `swift test`, `python3 test_client.py`, and `script/build_and_run.sh --verify` on the Mac before packaging a DMG for this tag.

**Follow-up in the same pass**: A self-review after `v1.0.3` was published found two session-semantics gaps, fixed and released as `v1.0.4` (which supersedes `v1.0.3`): the legacy `POST /<connector>/message` endpoint now scopes `sessionId` to the connector in the route, and Streamable HTTP requests presenting a stale `Mcp-Session-Id` return 404 for client re-initialization instead of silently reaching a fresh, uninitialized connector process.

**Left off at**: Source release `v1.0.4` published from the branch. DMG packaging/notarization (`script/package_release.sh 1.0.4`, `script/notarize_release.sh`) still happens on the Mac and can be attached to the release afterwards.

---

## 2026-06-26 - Bridgeport 1.0.2 production connector release

**What changed**: Completed the production hardening pass for Bridgeport's public YNAB connector path. Added a launchd helper for reliable daemon restarts, moved blocking process reads off Swift's cooperative executor, made 1Password local-env FIFO reads non-blocking, fixed pane-targeted settings launch routing for packaged app verification, and preserved YNAB production write capability while allowing validation runs to force read-only behavior with a temporary Bridgeport env override.

**Provider verification**: Claude has one connected `ynab-mcp-server` custom connector pointed at the private production endpoint (redacted from the public-readiness tree); a read-only `Review unapproved` conversation returned the approval queue summary without approval, edit, category, delete, create, import, or other write actions. Mistral Vibe has one private connected `bridgeport_ynab` connector pointed at the same endpoint; read-only transaction review completed without mutation, and the function permissions leave write/interactive tools requiring approval while read-only tools are allowed. Mistral currently stores `icon_url: null` for this private custom MCP connector and exposes reconnect/disconnect only, so it renders the generic custom connector glyph; Bridgeport's `/icons/ynab` endpoint itself returns the YNAB PNG, not a Cloudflare icon.

**Live verification**: The Bridgeport daemon and Cloudflare named tunnel are running for a private production hostname (redacted from the public-readiness tree). Only `ynab-mcp-server` is public at `/mcp/ynab`; Apple Notes remains local/private and returns 404 on a public route. Public OAuth metadata, public icon serving, and a read-only YNAB MCP probe all pass; the public YNAB server advertises 51 tools, including write tools for production use, while the validation probe used read-only review calls only.

**Release verification**: `swift test` passed 32 tests. `python3 test_client.py` passed all 11 smoke tests. The packaged settings UI opens directly to the Cloudflare pane with the tunnel running. `dist/release/Bridgeport-1.0.2.dmg` is signed, notarized, stapled, and accepted by Gatekeeper; SHA-256 is `39cc3a79d0bc3fbf36c3aff8da7d36fe6c3fc5582bb5003506630985f907b23b`.

**Left off at**: No open blockers for the connector goal. This entry records the verified source and artifact state for the `v1.0.2` release.

---

## 2026-06-26 - Bridgeport-owned Cloudflare tunnel lifecycle checkpoint

**What changed**: Added a Bridgeport-owned Cloudflare settings model, a `CloudflareManager` for named tunnel status/config/bootstrap/start/stop/restart, CLI flags for those lifecycle operations, menu bar Cloudflare status, and a full Cloudflare settings pane. Updated README, CLOUDFLARE.md, and the MCP hosting plan to document the chosen stable named-tunnel architecture, private deployment defaults, bring-your-own-Cloudflare fields, and the distinction between remote MCP endpoints and webhook compatibility endpoints.

**Decisions made**: Use one production named Cloudflare Tunnel and one provider-compatible hostname, with Bridgeport enforcing per-connector enabled/public/auth/path decisions. Do not use quick tunnels as the production path. Keep Cloudflare disabled by default, preload only non-secret private deployment defaults, and keep Cloudflare credential material in `cloudflared` credentials, environment variables, or `op://` references rather than source or app bundle state.

**Left off at**: The Cloudflare lifecycle code, docs, and focused tests are local and uncommitted. A live packaged-app check exposed that the `--open-settings=cloudflare` path did not create an accessible settings window during this run; that needs a dedicated follow-up before claiming UI acceptance. The broader 1.0 release goal remains open.

**Open questions**: Finish live Cloudflare tunnel creation/start/stop/restart against the real account after credentials are confirmed. Then complete the required live Mistral and Claude YNAB read-only connector tests, logo verification, duplicate-connector checks, notarization, DMG packaging, and GitHub release.

---

## 2026-06-26 - Release hardening and connector UI polish

**What changed**: Hardened Bridgeport's public MCP surface, OAuth flow, local config handling, 1Password/env resolution, connector discovery, generated cloud connector exports, Mistral icon metadata, and packaged macOS UI. Added app icon assets, a pane-targeted settings launch hook for packaged UI verification, updated README/Cloudflare docs, and rebuilt the signed release-candidate DMG.

**Decisions made**: Keep query-token auth disabled by default. Claude custom connectors use Bridgeport OAuth 2.1 with PKCE. Mistral Work/Vibe connectors use Bearer auth and should be created from the generated payload so `icon_url` points at Bridgeport's cache-busted `/icons/<connector>?v=...` endpoint. URL-only hosted MCPs are skipped because Bridgeport is for local stdio MCPs.

**Verification**: `swift test` passed with 24 tests. `python3 test_client.py` passed all 11 smoke checks, including auth rejection, legacy SSE, Streamable HTTP, public icon HEAD/GET, scoped OAuth resource handling, Origin rejection, and oversized-body rejection. `codesign --verify` passed for `dist/release/Bridgeport.app` and `dist/release/Bridgeport-1.0-rc-current.dmg`; Gatekeeper still reports the expected unnotarized Developer ID state before notarization.

**Left off at**: Local code, docs, UI screenshots, signing, and smoke tests are in good RC shape. The active goal is not complete because provider-side Mistral and Claude custom connector testing still must be performed with computer control.

**Open questions**: Remove the duplicate Mistral Bridgeport YNAB connectors and recreate one private connector with the YNAB icon. Then test both Mistral and Claude conversations against the YNAB connector in read-only mode, notarize the 1.0 DMG, and publish the GitHub release.

---
