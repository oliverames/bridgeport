# Bridgeport MCP Hosting Plan

## Product Position

Bridgeport is a personal MCP gateway for Mac-local and self-hosted-only connectors. The release scope supports a user's always-on Mac and private domain without seeding maintainer-specific paths or deployment values.

Bridgeport's primary provider-facing surface is not a generic webhook. Provider setup should be described as authenticated remote MCP over Streamable HTTP, with legacy SSE support where a provider still needs it. The webhook route remains a connector-specific compatibility endpoint for integrations that send inbound events.

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
  - `.codex/config.toml`
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
- Bridgeport-owned Cloudflare settings with blank identity fields and editable bring-your-own-Cloudflare values.
- Bridgeport-managed named Cloudflare Tunnel lifecycle through `cloudflared`, including local config generation, LaunchAgent installation, status, create or repair, start, stop, and restart controls.
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
  "publicBaseURL": "https://mcp.example.com",
  "bindHost": "127.0.0.1",
  "allowedOrigins": [
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "https://mcp.example.com"
  ],
  "allowQueryTokenAuth": false,
  "connectorsPath": "/Users/example/.config/bridgeport/connectors",
  "additionalConnectorPaths": [
    "/Users/example/.claude/settings.json",
    "/Users/example/.codex/config.toml"
  ],
  "importedConnectors": {},
  "connectorSettings": {
    "ynab-mcp-server": {
      "enabled": true,
      "exposePublicly": true,
      "publicPath": "ynab"
    },
    "apple-notes": {
      "enabled": true,
      "exposePublicly": false,
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
  "cloudflare": {
    "enabled": false,
    "profileName": "Personal tunnel",
    "accountId": "",
    "zoneId": "",
    "domain": "example.com",
    "hostname": "mcp.example.com",
    "tunnelName": "bridgeport",
    "tunnelId": "",
    "credentialsFilePath": "",
    "configFilePath": "~/.config/bridgeport/cloudflared/config.yml",
    "cloudflaredPath": "/opt/homebrew/bin/cloudflared",
    "launchAgentLabel": "com.oliverames.bridgeport.cloudflared",
    "routeMode": "single-hostname-path-routing",
    "apiTokenEnvVar": "CLOUDFLARE_API_TOKEN",
    "apiTokenOPReference": "",
    "createdByBridgeport": false
  },
  "env": {
    "YNAB_API_TOKEN": "op://Development/<item>/<field>"
  }
}
```

Generated file: `~/.config/bridgeport/mcp_config.json`.

```json
{
  "mcpServers": {
    "ynab-mcp-server": {
      "type": "http",
      "url": "https://mcp.example.com/mcp/ynab",
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
      "name": "YNAB (BridgePort)",
      "remoteMCPServerURL": "https://mcp.example.com/mcp/ynab",
      "readyForClaudeApp": true
    }
  ],
  "anthropicMessagesAPIMCPServers": [
    {
      "type": "url",
      "name": "ynab-mcp-server",
      "url": "https://mcp.example.com/mcp/ynab",
      "authorization_token": "ames_..."
    }
  ],
  "mistralCustomConnectors": [
    {
      "name": "ynab-mcp-server",
      "serverURL": "https://mcp.example.com/mcp/ynab",
      "authenticationMethod": "HTTP Bearer Token",
      "apiCreatePayload": {
        "title": "YNAB (BridgePort)",
        "name": "ynab_bridgeport",
        "icon_url": "https://mcp.example.com/icons/ynab?v=..."
      }
    }
  ]
}
```

## Cloudflare Deployment Shape

Recommended personal deployment:

- Bridgeport daemon listens on `127.0.0.1:<port>`.
- Bridgeport owns a named Cloudflare Tunnel, by default named `bridgeport`.
- Bridgeport writes `~/.config/bridgeport/cloudflared/config.yml`.
- Bridgeport writes `~/Library/LaunchAgents/com.oliverames.bridgeport.cloudflared.plist` for the tunnel process.
- `cloudflared` routes `mcp.example.com` to `http://127.0.0.1:<port>`.
- Bridgeport validates `Authorization: Bearer <token>`.
- Bridgeport advertises `WWW-Authenticate: Bearer` for unauthenticated requests so remote connector platforms can detect Bearer auth.
- Cloudflare Access and WAF rules can further restrict who can call the hostname and which paths/methods are allowed.
- Public connector URLs are generated from `publicBaseURL` only when a connector's Public toggle is enabled.
- Bridgeport returns unavailable responses for disabled, private, or unknown connectors even when the Cloudflare hostname still routes to Bridgeport.
- Bridgeport reuses an existing tunnel with the configured name, creates a tunnel only when none exists, and reruns DNS route setup idempotently.

The chosen Cloudflare model is a stable named tunnel plus a DNS route for one provider-compatible hostname. Cloudflare Workers are not required for the release-candidate architecture because Bridgeport already performs MCP routing, token enforcement, connector metadata, and icon serving locally. Quick tunnels are for temporary development only and are not the production path.

The route mode is intentionally `single-hostname-path-routing`: Cloudflare forwards the hostname to Bridgeport, while Bridgeport enforces per-connector enabled, public, auth, and path decisions. This avoids creating one Cloudflare DNS record per connector and prevents Cloudflare endpoint state from overriding connector identity or icons.

Example endpoints:

- `https://mcp.example.com/mcp/ynab`
- `https://mcp.example.com/ynab-mcp-server/webhook`
- `https://mcp.example.com/status`

## Security Posture

Release-candidate defaults:

- Localhost bind by default.
- Query-string token auth disabled by default.
- No request-body logging.
- Constant-time bearer-token comparisons.
- One MiB request-body limit for JSON-RPC and webhook posts.
- Public route paths normalized to a safe single path segment.
- `op://` values resolved at process start instead of persisted in generated client config.
- Default Bridgeport env values are seeded from the canonical `~/.claude/.env` `op://` map, not plaintext Claude settings values.
- Public exposure requires a per-connector toggle.
- URL-only web-hosted MCPs are skipped.
- Cloudflare is disabled by default and must be explicitly enabled before Bridgeport writes tunnel config or exposes public connector URLs.
- Cloudflare credential material is not stored in source control or the app bundle. Use `cloudflared tunnel login`, a local credentials file, environment variables, or `op://` references.
- Cloudflare tunnel logs are written under Bridgeport's config directory and should stay at warning verbosity.

Still worth considering after RC:

- Per-connector token scopes.
- Keychain storage for the Bridgeport master token.
- Built-in 1Password Environment creation through the 1Password MCP tools.
- Cloudflare Access policy scaffolding through the Cloudflare API.
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
