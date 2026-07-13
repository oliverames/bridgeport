# Bridgeport Threat Model

## Scope

This model covers the Bridgeport menu-bar app, its LaunchAgent daemon, generated configuration, OAuth endpoints, MCP HTTP/SSE routes, connector subprocesses, and the optional `cloudflared` LaunchAgent. It assumes one trusted macOS user account operating a personal gateway.

## Assets

- The Bridgeport master bearer token and issued OAuth access tokens.
- Connector-specific credentials and `op://` references.
- Local application data reachable through connectors.
- Connector commands, arguments, source paths, and public/private exposure choices.
- Cloudflare tunnel credentials and DNS routing state.
- The integrity and availability of the Mac running Bridgeport.

## Trust Boundaries

1. A local or remote MCP client crosses an HTTP boundary into Bridgeport.
2. A public client crosses Cloudflare and the user's tunnel before reaching Bridgeport.
3. Bridgeport crosses a process boundary when it launches a configured stdio connector.
4. Connector output crosses back into Bridgeport and then to the requesting client.
5. Imported configuration, plugin manifests, mounted environment files, and `op://` values cross a local filesystem or credential-manager boundary.
6. Bridgeport crosses a privileged local-management boundary when it writes or controls user LaunchAgents and when it invokes `cloudflared` or `op`.

## Threats and Controls

### Unauthorized remote connector access

Risk: an attacker calls a public MCP, webhook, icon, status, or OAuth route and reaches local data or tools.

Controls:

- The daemon binds to `127.0.0.1` by default.
- Bearer authentication is required for MCP, webhook, and status routes.
- Bearer comparisons are constant-time.
- Query-string token authentication is disabled by default.
- OAuth uses authorization codes with PKCE, resource scoping, expiring codes and tokens, and uncacheable token responses.
- Failed master-token approval attempts are delayed.
- Each connector must be enabled, and public requests additionally require its **Public** toggle.
- Public route paths are normalized to one safe segment.
- Browser-originated requests are checked against the configured origin list.

Residual risk: the Bridgeport master token grants broad access to every enabled route. Use Cloudflare Access, WAF rules, and rate limiting as a second boundary. Rotate the token after suspected disclosure.

### Unintended connector exposure

Risk: discovery makes a local connector remotely reachable without a deliberate choice.

Controls:

- Newly discovered local connectors are private until explicitly exposed.
- URL-only hosted MCPs are skipped because Bridgeport is intended for local stdio processes.
- Public client exports include only enabled connectors with **Public** enabled.
- Icon and metadata routes follow the same local/public exposure rules as MCP routes.

Residual risk: imported configuration can change on disk, and a mirrored command may later point to different code. Review mirrored sources after updates.

### Malicious or compromised connector

Risk: a connector executes arbitrary code, reads local data, leaks environment values, returns hostile output, or consumes resources.

Controls:

- Bridgeport passes environment values only from the configured precedence chain and resolves only references the connector declares or uses.
- Unused 1Password references are not injected into unrelated connector processes.
- Connector stdin is serialized, stdout lines are capped, and termination escalates after a grace period.
- Sessions expire when idle, and the daemon caps simultaneous live sessions.

Residual risk: a connector runs with the signed-in user's permissions. Bridgeport is not a sandbox and cannot make untrusted connector code safe. Review and trust a connector before enabling it.

### Request and session resource exhaustion

Risk: large requests, reconnect loops, abandoned streams, or noisy subprocesses exhaust memory, file descriptors, or processes.

Controls:

- JSON-RPC, OAuth, and webhook request bodies are limited to one MiB.
- Active sessions are capped, excess sessions receive `503` and `Retry-After`, and idle sessions are reaped.
- Connector stdout lines are capped and HTTP responses are streamed in chunks.

Residual risk: an authenticated connector tool can still perform expensive work. External rate limits remain necessary on a public hostname.

### Credential disclosure at rest or in logs

Risk: generated config, OAuth stores, URLs, errors, or logs expose tokens and connector secrets.

Controls:

- The config directory is mode `0700`; sensitive config and OAuth files are mode `0600`.
- Query-token URLs are off by default and described as a compatibility fallback only.
- OAuth token responses use `Cache-Control: no-store` and `Pragma: no-cache`.
- MCP request bodies and resolved secrets are not intentionally logged.
- Cloudflare command errors are sanitized before Bridgeport logs them.

Residual risk: values are not encrypted by Bridgeport, and connector or third-party logs are outside Bridgeport's control. Use FileVault, protect backups, and inspect connector logging behavior.

### Unsafe local configuration or path handling

Risk: crafted names or paths escape expected files, generate unsafe routes, or corrupt LaunchAgent configuration.

Controls:

- Route and generated connector identifiers are normalized.
- LaunchAgent property lists are produced with structured serialization rather than string interpolation.
- Generated Cloudflare YAML quotes user-controlled values.
- Existing malformed Bridgeport configuration is not overwritten automatically.

Residual risk: a local attacker who can modify the user's configuration or connector source already has substantial access within that account.

## Explicit Non-Goals

Bridgeport does not defend against:

- A malicious administrator, root process, or another process already able to read the user's files and memory.
- Untrusted connector code running safely under the same macOS account.
- Multi-tenant isolation between unrelated users.
- Encryption of Bridgeport configuration at rest.
- Availability attacks performed through an authorized connector's legitimate expensive operations.
- Privacy or security failures inside Cloudflare, 1Password, an MCP provider, or a connector subprocess.

## Release Security Checks

Each release should pass Swift tests, isolated HTTP smoke tests, a release build, clean-install verification, full-history Gitleaks scanning, Developer ID signature verification, notarization, stapling, and Gatekeeper assessment. See [RELEASING.md](../RELEASING.md).
