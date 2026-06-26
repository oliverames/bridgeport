# Bridgeport MCP Hosting Plan

## Product Position

Bridgeport is a personal MCP gateway for Mac-local and self-hosted-only connectors. The release-candidate scope is focused on Oliver's own always-on Mac and private domains, but the app is structured as if it could be cleaned up for public release later.

Bridgeport should host:

- MCP servers that need macOS app data or local automation, for example `apple-notes-mcp`.
- MCP servers that could be hosted elsewhere but are cheaper and simpler to run personally, for example `ynab-mcp-server`.
- Connectors from local plugin repos or installed plugin caches when they launch a local process.

Bridgeport should not host:

- URL-only hosted MCPs that already have a public endpoint.
- Hosted HTML/web connectors that can be added directly to the client.
- Arbitrary newly discovered connectors unless the user enables or exposes them intentionally.

## Implemented Release-Candidate Scope

- macOS 26 Tahoe SwiftUI menu bar app with Dashboard, Connectors, Security, Cloudflare, Cloud Connectors, 1Password, and Sources settings panes.
- LaunchAgent daemon install, status, restart, uninstall, and token rotation.
- Localhost bind by default (`127.0.0.1`) with configurable bind host.
- Bearer-token authentication by default, with query-token fallback off unless explicitly enabled.
- Origin validation for browser-originated requests.
- Streamable HTTP endpoint shape: `/mcp/<connector>`.
- Legacy SSE endpoint shape: `/<connector>/sse` plus `/<connector>/message`.
- Runtime status endpoint at `/status`.
- Webhook endpoint at `/<connector>/webhook`.
- Active session counts surfaced in the UI and status JSON.
- Connector discovery from:
  - `.mcp.json`
  - `.claude-plugin/plugin.json`
  - `.codex-plugin/plugin.json`
  - `.antigravity-plugin/mcp_config.json`
  - `.hermes-plugin/plugin.json`
  - `.claude/settings.json`
- Relative `mcpServers` manifest pointers, such as `"./.mcp.json"`.
- Import MCP definitions into Bridgeport config.
- Mirror MCP definitions from external files or directories.
- Per-connector enabled, public exposure, and public path settings.
- Generated MCP client config at `~/.config/bridgeport/mcp_config.json`.
- Generated client config uses HTTP MCP entries and `Authorization` headers.
- Generated cloud connector export at `~/.config/bridgeport/cloud_connectors.json`.
- Claude custom connector export for public connectors, including a ready/pending marker based on query-token fallback.
- Anthropic Messages API MCP server definitions using `authorization_token`.
- Mistral Work custom connector details using HTTP Bearer Token auth.
- Vibe Code CLI TOML snippets using `streamable-http` plus `Authorization` headers.
- 1Password support through:
  - Mounted 1Password Environment `.env` file.
  - `op://` reference resolution through the 1Password CLI.
- Test isolation through `BRIDGEPORT_CONFIG_HOME`.

## Config Model

Primary file: `~/.config/bridgeport/config.json`.

```json
{
  "token": "ames_...",
  "port": 8080,
  "publicBaseURL": "https://mcp.amesvt.com",
  "bindHost": "127.0.0.1",
  "allowedOrigins": [
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "https://mcp.amesvt.com"
  ],
  "allowQueryTokenAuth": false,
  "connectorsPath": "/Users/oliverames/Developer/Projects/ames-connectors/plugins",
  "additionalConnectorPaths": [
    "/Users/oliverames/Developer/Projects/ynab-mcp-server",
    "/Users/oliverames/.claude/settings.json"
  ],
  "importedConnectors": {},
  "connectorSettings": {
    "apple-notes": {
      "enabled": true,
      "exposePublicly": true,
      "publicPath": "apple-notes"
    }
  },
  "onePasswordEnvironment": {
    "enabled": true,
    "environmentName": "Bridgeport",
    "accountId": "",
    "environmentId": "",
    "localEnvFilePath": "~/.config/bridgeport/1password.env"
  },
  "env": {
    "YNAB_API_TOKEN": "op://Development/YNAB/api-token"
  }
}
```

Generated file: `~/.config/bridgeport/mcp_config.json`.

```json
{
  "mcpServers": {
    "apple-notes": {
      "type": "http",
      "url": "https://mcp.amesvt.com/mcp/apple-notes",
      "headers": {
        "Authorization": "Bearer ames_..."
      }
    }
  }
}
```

Generated file: `~/.config/bridgeport/cloud_connectors.json`.

```json
{
  "claudeCustomConnectors": [
    {
      "name": "apple-notes",
      "remoteMCPServerURL": "https://mcp.amesvt.com/mcp/apple-notes",
      "readyForClaudeApp": false
    }
  ],
  "anthropicMessagesAPIMCPServers": [
    {
      "type": "url",
      "name": "apple-notes",
      "url": "https://mcp.amesvt.com/mcp/apple-notes",
      "authorization_token": "ames_..."
    }
  ],
  "mistralCustomConnectors": [
    {
      "name": "apple-notes",
      "serverURL": "https://mcp.amesvt.com/mcp/apple-notes",
      "authenticationMethod": "HTTP Bearer Token"
    }
  ]
}
```

## Cloudflare Deployment Shape

Recommended personal deployment:

- Bridgeport daemon listens on `127.0.0.1:<port>`.
- `cloudflared` routes `mcp.amesvt.com` to `http://localhost:<port>`.
- Bridgeport validates `Authorization: Bearer <token>`.
- Bridgeport advertises `WWW-Authenticate: Bearer` for unauthenticated requests so remote connector platforms can detect Bearer auth.
- Cloudflare Access and WAF rules restrict who can call the hostname and which paths/methods are allowed.
- Public connector URLs are generated from `publicBaseURL` only when a connector's Public toggle is enabled.

Example endpoints:

- `https://mcp.amesvt.com/mcp/apple-notes`
- `https://mcp.amesvt.com/mcp/ynab-mcp-server`
- `https://mcp.amesvt.com/ynab-mcp-server/webhook`
- `https://mcp.amesvt.com/status`

## Security Posture

Release-candidate defaults:

- Localhost bind by default.
- Query-string token auth disabled by default.
- No request-body logging.
- `op://` values resolved at process start instead of persisted in generated client config.
- Public exposure requires a per-connector toggle.
- URL-only web-hosted MCPs are skipped.

Still worth considering after RC:

- Per-connector token scopes.
- Keychain storage for the Bridgeport master token.
- Built-in 1Password Environment creation through the 1Password MCP tools.
- Cloudflare Access policy scaffolding.
- Signed and notarized distribution.

## Comparable Products And Patterns

Bridgeport is not trying to replace these:

- MCP Inspector and local MCP testing tools.
- Cloudflare Tunnel, ngrok, or Tailscale Funnel.
- Smithery, Composio, Pipedream, Zapier, or other hosted connector catalogs.
- Claude Desktop, Claude Code, Codex, or Antigravity MCP launch configs.

The useful differentiator is the combination of local discovery, per-connector toggles, credential resolution, process supervision, generated client config, and private remote access from an always-on Mac.

## Name

Keep **Bridgeport**.

Tagline: **Personal MCP gateway for Mac-local connectors.**
