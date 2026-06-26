## 2026-06-26 - Release hardening and connector UI polish

**What changed**: Hardened Bridgeport's public MCP surface, OAuth flow, local config handling, 1Password/env resolution, connector discovery, generated cloud connector exports, Mistral icon metadata, and packaged macOS UI. Added app icon assets, a pane-targeted settings launch hook for packaged UI verification, updated README/Cloudflare docs, and rebuilt the signed release-candidate DMG.

**Decisions made**: Keep query-token auth disabled by default. Claude custom connectors use Bridgeport OAuth 2.1 with PKCE. Mistral Work/Vibe connectors use Bearer auth and should be created from the generated payload so `icon_url` points at Bridgeport's cache-busted `/icons/<connector>?v=...` endpoint. URL-only hosted MCPs are skipped because Bridgeport is for local stdio MCPs.

**Verification**: `swift test` passed with 24 tests. `python3 test_client.py` passed all 11 smoke checks, including auth rejection, legacy SSE, Streamable HTTP, public icon HEAD/GET, scoped OAuth resource handling, Origin rejection, and oversized-body rejection. `codesign --verify` passed for `dist/release/Bridgeport.app` and `dist/release/Bridgeport-1.0-rc-current.dmg`; Gatekeeper still reports the expected unnotarized Developer ID state before notarization.

**Left off at**: Local code, docs, UI screenshots, signing, and smoke tests are in good RC shape. The active goal is not complete because provider-side Mistral and Claude custom connector testing still must be performed with computer control.

**Open questions**: Remove the duplicate Mistral Bridgeport YNAB connectors and recreate one private connector with the YNAB icon. Then test both Mistral and Claude conversations against the YNAB connector in read-only mode, notarize the 1.0 DMG, and publish the GitHub release.

---
