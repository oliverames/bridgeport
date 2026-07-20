## 2026-07-20 - Home-server deployment, 1.0.7 release, apple-notes perf fix

**What changed**: Deployed Bridgeport to home-server as its production host: installed from the v1.0.6 DMG, daemon LaunchAgent running, single connector `apple-notes` (npm `apple-notes-mcp` 2.6.x pinned in `~/.config/bridgeport/connectors/apple-notes`), Cloudflare tunnel `bridgeport-home-server` (132665b6) serving `https://mcp.amesvt.com`, exported as "Apple Notes (BridgePort)" with the real Notes app icon, connected to Oliver's Claude account via the OAuth 2.1 flow. Released **1.0.7** (tagged, notarized, DMG + sha256 on GitHub, home-server upgraded): `NSAppleEventsUsageDescription` added to both bundle-plist heredocs (`build_and_run.sh` in 3d99a42, `package_release.sh` in d28c222 — the two scripts have independent Info.plist heredocs and had drifted), `--daemon-install`/AppState now point the LaunchAgent at the app bundle binary when running from a bundle (`LaunchAgentManager.bundleExecutablePath`), and a Launch-at-login toggle (SMAppService) landed in Dashboard > Service.

**Decisions made**: The `mcp.amesvt.com` CNAME was repointed from the dead MacBook `bridgeport` tunnel to the new home-server tunnel with `cloudflared tunnel route dns --overwrite-dns` (Bridgeport's route step refuses to clobber an existing record). This formally ends the MacBook's legacy public `ynab` entry noted in the 2026-07-18 inventory; it had been returning 530 already. Connector perf was fixed at the root in the upstream project rather than worked around: `apple-notes-mcp` sent two Apple Events per note and used per-note-evaluated `whose` clauses, so full-library tools exceeded Claude's 60s tool timeout on a 524-note library. Bulk whole-list fetches + local AppleScript date comparison took `modifiedSince` from 63s to 6.7s and health-check from fatal to ~10s. Upstream PR sweetrb/apple-notes-mcp#86 is open with CI green (repo gates PRs on a version bump; 2.6.1 + changelog included); the patched build is hand-deployed into the home-server connector's node_modules until 2.6.1 ships.

**Verification**: swift test (44), test_client.py, gitleaks, clean-install probe on both the dev bundle and the notarized DMG; live end-to-end checks over the tunnel (OAuth metadata, 401 challenge, icon ETag route, authenticated initialize, real Notes reads); upstream suite 477 tests + lint/typecheck/format green locally and in PR CI. TCC root cause proven live: bare-binary daemon was silently denied Apple Events, bundle-path daemon prompts and works.

**Left off at**: PR #86 awaiting maintainer review. When 2.6.1 publishes, replace the hand-patched `build/index.js` on home-server with `npm update apple-notes-mcp`. Known operational gotchas recorded in project memory: osascript from SSH is TCC-blocked and hangs to -1712 (mimics a wedged Notes.app); Notes must be relaunched from the daemon/console context. Claude's 60s tool limit remains the binding constraint for any future connector with slow tools.

**Open questions**: Whether Bridgeport should cap or serialize concurrent subprocesses per connector; a Claude retry storm spawned six apple-notes processes that starved each other against Notes' serialized Apple Events queue until the 10-minute session reaper caught up.

---

## 2026-07-18 - Discover enabled external plugins from the marketplace external_plugins dir

**What changed**: `ConnectorManager.candidatePluginLocations` now also searches `~/.claude/plugins/marketplaces/<marketplace>/external_plugins/<plugin>`. Previously it looked only in the plugin cache and `~/Developer/Projects`, so a plugin the marketplace vendors from a third party (for example `imessage@claude-plugins-official`) was undiscoverable through `enabledPlugins` even when enabled in Claude Code. This resolves the follow-up noted in the prior "Wired iMessage" entry.

**Decisions made**: Kept the fix to the one function and the single missing search location rather than adding a home-directory injection seam. `candidatePluginLocations` reads the real home directory, which is exactly why it has no unit test today: any test would depend on plugins actually installed on the machine and would not be hermetic in CI. Adding an injection seam would be a larger refactor than the fix warrants, so it is left as a possible future improvement. The explicit `additionalConnectorPaths` entry for iMessage stays in the live config because iMessage is not enabled in Claude Code; if it is ever enabled, the connector resolves through both paths and name-dedup prevents double registration.

**Verification**: `swift build -c release` and `swift test` (44 tests) both passed. Live isolation test: ran the built binary with `BRIDGEPORT_CONFIG_HOME` pointed at a throwaway config whose `additionalConnectorPaths` contained only a synthetic `.claude/settings.json` enabling `imessage@claude-plugins-official`, with no direct plugin path. Discovery found `imessage` at the real `.../external_plugins/imessage` and wrote it to the isolated `mcp_config.json`, proving resolution went through the new branch. Before the change the same setup discovers zero connectors. Fixture and processes cleaned up afterward.

**Left off at**: Source change committed. No release repackaging was done; this is a source-level fix and the change is covered by the existing test suite plus the live isolation check.

---

## 2026-07-18 - Wired iMessage into the local vending set

**What changed**: No source files changed. Added the iMessage MCP as a served local connector by pointing `additionalConnectorPaths` at its plugin directory, `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/imessage`, so Bridgeport discovers it from the plugin's own `.mcp.json`. The connector is a stdio server (`command: bun`, `run --cwd ${CLAUDE_PLUGIN_ROOT} --shell=bun --silent start`), and its existing connectorSettings toggle (`enabled: true`, `exposePublicly: false`) already keeps it local-only, so it is not exposed through the tunnel.

**Why a path rather than the auto-discovery route**: Bridgeport's plugin auto-discovery only walks plugins listed in `enabledPlugins` and only searches the cache and Developer/Projects locations, not a marketplace's `external_plugins` directory. iMessage is installed as an external plugin and is not enabled in Claude Code, so neither condition was met and it was never discovered despite the toggle. Naming the plugin directory directly in `additionalConnectorPaths` decouples Bridgeport's vending from Claude Code's own enable state, which is the intended behavior since Bridgeport hosts the connector for other clients.

**Verification**: Ran `bridgeport --server` against the updated config. Discovery went from 20 to 21 connectors and logged `imessage` at `http://localhost:8085/mcp/imessage`; the regenerated `mcp_config.json` lists it as a local http entry. A live MCP `initialize` handshake to that route launched the `bun` iMessage server and returned a full capabilities result, confirming the route proxies to a working connector rather than only appearing in the list. `bun` is present at `/opt/homebrew/bin/bun`. The verification server and its spawned connector were stopped afterward, leaving port 8085 free.

**Not added**: `chrome-devtools` remains toggled-on but unserved; its only local source is a version-pinned cache directory (`.../chrome-devtools-mcp/1.5.0/`), so wiring it would hardcode a path that breaks on the next plugin update. The other local stdio external plugins available in the same marketplace (`discord`, `telegram`, `fakechat`) were left out because they were not requested. A cleaner future option is teaching `candidatePluginLocations` to also search `marketplaces/<marketplace>/external_plugins/<plugin>` so enabled external plugins discover without an explicit path.

---

## 2026-07-18 - Local connector inventory and stale-toggle cleanup

**What changed**: No source files changed. Reviewed the live vending surface against the history and worklog to answer which connectors Bridgeport still serves locally now that YNAB no longer depends on the bridge. The generated `~/.config/bridgeport/mcp_config.json` is the authoritative manifest: 20 connectors, 19 served locally at `http://localhost:8085/mcp/<name>` and one, `ynab-mcp-server`, exposed publicly at `https://mcp.amesvt.com/mcp/ynab`. Pruned four dead connector toggles from `config.json` connectorSettings that belonged to the archived `ames-connectors` marketplace and no longer resolve to a running server: `ames-unifi-mcp`, `imagerelay-mcp-server`, `lytho-mcp-server`, and `sprout-mcp-server`. The connectorSettings block dropped from 24 entries to 20.

**Findings**: The genuinely Mac-bound local connectors, the ones that justify the bridge existing, are `apple-mail`, `apple-notes`, `apple-notifier`, `drafts`, `paste`, `macos-automator`, `computer-use`, `XcodeBuildMCP`, `pdf`, `playwright`, and `onepassword` (tied to the local 1Password app auth). The remaining local connectors are portable rather than Mac-bound and could run anywhere: `apple-docs` (a network fetch of developer.apple.com despite the name), `google-workspace`, `merriam-webster`, `excel`, `markitdown`, `pandoc`, `node_repl`, and `mock-echo`. Because YNAB now runs through the standalone hosted `ynab-mcp-server` path rather than needing Bridgeport's stdio bridging, Bridgeport's only remaining public entry is effectively legacy, and its real ongoing job is exposing this Mac's native apps to remote AI clients.

**Left in place deliberately**: `imessage` and `chrome-devtools` remain enabled in connectorSettings but are not currently discovered, so they are toggled on yet not being vended. These read as wanted-but-not-resolving rather than abandoned, so they were kept rather than pruned; the open item is to confirm whether their sources are installed and discoverable.

**Verification**: `config.json` re-parsed as valid JSON after the edit; the four target keys are absent, `imessage`, `chrome-devtools`, and the public `ynab-mcp-server` entry are intact, and the daemon was not running during the edit so there was no concurrent-write risk. The daemon's encoder uses sorted keys, so its next settings save renormalizes formatting without reintroducing the pruned entries.

---

## 2026-07-13 - Current release gates

**Current state**: Bridgeport 1.0.6 is published as a normal GitHub release. The DMG is Developer ID signed, notarized, stapled, and accepted by Gatekeeper. The release workflow and local verification are complete, so signing and packaging are no longer release blockers.

**What remains**: The private repository makes the release available only to people who already have access. Before offering a public download, either select a source license and make the repository public, or use a separate public binary-distribution channel. If the source repository becomes public, first decide whether to rewrite the older maintainer paths and private deployment hostname or start from a clean public history. A Mac App Store version would be a separate product effort because the current helper, LaunchAgent, file access, and command-line integrations do not fit the sandboxed store build.

---

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
