# Bridgeport Local Connector E2E Test Log - 2026-07-08 UTC

Local time during browser testing: 2026-07-07 evening America/New_York.

## Scope

- Local Bridgeport status exposed 25 enabled MCP servers.
- The generated cloud connector export exposed only `YNAB (BridgePort)` for Claude and Mistral, backed by `https://mcp.amesvt.com/mcp/ynab`.
- All other local connectors were local-only in the active config and were not addable to Mistral or Claude from the current cloud export.
- Test prompt used in Mistral and Claude: ask YNAB for unapproved transactions with `review_unapproved` and `summary: true`, then report only aggregate counts.
- No tokens, OAuth codes, transaction IDs, payees, or amounts were logged.

## Runtime State

- `gui/501/com.oliverames.bridgeport`: running.
- `gui/501/com.oliverames.bridgeport.cloudflared`: running.
- Local YNAB MCP endpoint: `http://127.0.0.1:8085/mcp/ynab`.
- Public YNAB MCP endpoint: `https://mcp.amesvt.com/mcp/ynab`.

## Verification Matrix

| Check | Result | Evidence |
| --- | --- | --- |
| Swift test suite | Pass | `swift test` passed 42 tests. |
| Smoke client | Pass | `python3 test_client.py` passed after the compile fix. |
| Packaged app verify | Pass | `script/build_and_run.sh --verify` completed successfully. |
| Local YNAB MCP | Pass | `tools/list` returned 51 tools, including `review_unapproved`; summary returned total 28. |
| Public YNAB MCP | Pass with curl-like client | `tools/list` returned 51 tools, including `review_unapproved`; summary returned total 28, 11 need categorization first, 17 ready to approve. |
| Mistral Work connector | Pass after reconnect | Visual Safari test showed `YNAB (BridgePort)` connected and Mistral reported total 28, with 11 needing categorization. |
| Claude connector | Fail | Visual Safari test showed Claude could list/connect `YNAB (BridgePort)`, but `review_unapproved` was not exposed in Claude's available toolset for the chat. |

## Issues Found

### 1. Build failed on missing `SSEServer.maxSessions`

- Status: fixed.
- Symptom: `swift test` failed to compile with `type 'Self' has no member 'maxSessions'`.
- Fix: added `private static let maxSessions = 64` to `SSEServer`.
- Verification: `swift test`, `python3 test_client.py`, and `script/build_and_run.sh --verify` passed.

### 2. Public Cloudflare edge blocks Python urllib-style clients

- Status: open, worked around during testing.
- Symptom: Python `urllib` POSTs to Bridgeport public OAuth/MCP routes returned 403 responses; the OAuth approval attempt returned a Cloudflare 1010 page.
- Workaround: use a curl-like client signature. The same public MCP JSON-RPC calls passed with a curl-style user agent.
- Impact: browser provider flows can still work, but non-browser automation that uses default Python networking can be blocked before reaching Bridgeport.

### 3. Mistral required connector reconnect

- Status: fixed for this session.
- Symptom: Mistral showed `YNAB (BridgePort)` as available but `Connection required`.
- Action: completed the Bridgeport OAuth approval flow for Mistral.
- Verification: Mistral completed the chat request and matched the direct public MCP aggregate result.

### 4. Claude OAuth connection had expired

- Status: fixed at the account-connector level.
- Symptom: Claude settings showed `YNAB (BridgePort)` with an expired connection.
- Action: reconnected through the Bridgeport OAuth approval flow.
- Verification: Claude showed a successful connection toast and listed `YNAB (BridgePort)` under connectors afterward.

### 5. Claude did not expose YNAB tools to the chat session

- Status: open.
- Symptom: after OAuth reconnection, with `YNAB (BridgePort)` listed under Connectors and tool access set to `Tools already loaded`, Claude still said `review_unapproved` was not available in its toolset.
- Reproduction: occurred in both the original chat retry and a fresh Claude chat.
- Bridgeport-side check: local and public MCP calls both advertised 51 tools and successfully executed `review_unapproved`.
- Likely next area: Claude custom connector session/tool-discovery behavior, not the Bridgeport YNAB endpoint itself.

### 6. "All local connectors" are not all cloud-exported

- Status: open scope gap.
- Observation: Bridgeport had 25 local MCP servers enabled, but the cloud connector export for Claude/Mistral included only YNAB.
- Impact: the requested Mistral/Claude E2E test was possible only for YNAB using the current export. The remaining local connectors need explicit public exposure settings before they can be added to cloud AI clients.
