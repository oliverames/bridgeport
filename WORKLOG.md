## 2026-07-02 - Bridgeport 1.0.3 reliability and robustness pass

**What changed**: Comprehensive reliability review of the daemon's serving path. SSE/streamable HTTP responses now stream chunked byte buffers instead of one byte at a time, sessions track activity and an idle reaper closes abandoned sessions so disconnected clients no longer leak connector subprocesses, `Mcp-Session-Id` values are scoped to the connector that issued them (including DELETE), OAuth access tokens persist across daemon restarts so connected Claude custom connectors survive settings saves without re-authorizing, the OAuth client registry is capped at 256 entries, connector stdin writes moved off the cooperative executor onto a serial queue, connector shutdown now closes stdin and escalates SIGTERM to SIGKILL after a 5s grace period, connector stdout lines are capped at 32 MB, `runShell` drains stderr concurrently to remove a pipe-buffer deadlock, and the cloudflared tunnel lookup no longer misreads Go zero timestamps in `deleted_at` as deletions. Added a tag-push GitHub Actions workflow that publishes releases from annotated tags.

**Verification**: Authored on a Linux CI container without a macOS toolchain: all Swift sources pass `swiftc -parse` syntax checking, and the changes ship with 5 new unit tests plus a new `test_client.py` smoke test (streamable HTTP session DELETE). Run `swift test`, `python3 test_client.py`, and `script/build_and_run.sh --verify` on the Mac before packaging a DMG for this tag.

**Follow-up in the same pass**: A self-review after `v1.0.3` was published found two session-semantics gaps, fixed and released as `v1.0.4` (which supersedes `v1.0.3`): the legacy `POST /<connector>/message` endpoint now scopes `sessionId` to the connector in the route, and Streamable HTTP requests presenting a stale `Mcp-Session-Id` return 404 for client re-initialization instead of silently reaching a fresh, uninitialized connector process.

**Left off at**: Source release `v1.0.4` published from the branch. DMG packaging/notarization (`script/package_release.sh 1.0.4`, `script/notarize_release.sh`) still happens on the Mac and can be attached to the release afterwards.

---

## 2026-06-26 - Bridgeport 1.0.2 production connector release

**What changed**: Completed the production hardening pass for Bridgeport's public YNAB connector path. Added a launchd helper for reliable daemon restarts, moved blocking process reads off Swift's cooperative executor, made 1Password local-env FIFO reads non-blocking, fixed pane-targeted settings launch routing for packaged app verification, and preserved YNAB production write capability while allowing validation runs to force read-only behavior with a temporary Bridgeport env override.

**Provider verification**: Claude has one connected `ynab-mcp-server` custom connector pointed at `https://mcp.amesvt.com/mcp/ynab`; a read-only `Review unapproved` conversation returned the approval queue summary without approval, edit, category, delete, create, import, or other write actions. Mistral Vibe has one private connected `bridgeport_ynab` connector pointed at the same endpoint; read-only transaction review completed without mutation, and the function permissions leave write/interactive tools requiring approval while read-only tools are allowed. Mistral currently stores `icon_url: null` for this private custom MCP connector and exposes reconnect/disconnect only, so it renders the generic custom connector glyph; Bridgeport's `/icons/ynab` endpoint itself returns the YNAB PNG, not a Cloudflare icon.

**Live verification**: The Bridgeport daemon and Cloudflare named tunnel are running for `https://mcp.amesvt.com`. Only `ynab-mcp-server` is public at `/mcp/ynab`; Apple Notes remains local/private and returns 404 on a public route. Public OAuth metadata, public icon serving, and a read-only YNAB MCP probe all pass; the public YNAB server advertises 51 tools, including write tools for production use, while the validation probe used read-only review calls only.

**Release verification**: `swift test` passed 32 tests. `python3 test_client.py` passed all 11 smoke tests. The packaged settings UI opens directly to the Cloudflare pane with the tunnel running. `dist/release/Bridgeport-1.0.2.dmg` is signed, notarized, stapled, and accepted by Gatekeeper; SHA-256 is `39cc3a79d0bc3fbf36c3aff8da7d36fe6c3fc5582bb5003506630985f907b23b`.

**Left off at**: No open blockers for the connector goal. This entry records the verified source and artifact state for the `v1.0.2` release.

---

## 2026-06-26 - Bridgeport-owned Cloudflare tunnel lifecycle checkpoint

**What changed**: Added a Bridgeport-owned Cloudflare settings model, a `CloudflareManager` for named tunnel status/config/bootstrap/start/stop/restart, CLI flags for those lifecycle operations, menu bar Cloudflare status, and a full Cloudflare settings pane. Updated README, CLOUDFLARE.md, and the MCP hosting plan to document the chosen stable named-tunnel architecture, `amesvt.com` defaults, bring-your-own-Cloudflare fields, and the distinction between remote MCP endpoints and webhook compatibility endpoints.

**Decisions made**: Use one production named Cloudflare Tunnel and one provider-compatible hostname, with Bridgeport enforcing per-connector enabled/public/auth/path decisions. Do not use quick tunnels as the production path. Keep Cloudflare disabled by default, preload only non-secret Oliver/private defaults, and keep Cloudflare credential material in `cloudflared` credentials, environment variables, or `op://` references rather than source or app bundle state.

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
