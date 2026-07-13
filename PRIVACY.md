# Privacy

Bridgeport is a local macOS utility. It does not include analytics, advertising, telemetry, crash reporting, or an account service operated by the project maintainer.

## Data Bridgeport Reads

Depending on the sources a user enables, Bridgeport can read local MCP configuration and plugin manifests, including Claude, Codex, Antigravity, and Hermes configuration files. It reads the command, arguments, source paths, and declared environment references needed to discover and launch connectors.

Bridgeport can also read a user-selected 1Password Environment mount and resolve declared `op://` references through the 1Password CLI. It limits resolved values to environment variables used or declared by the connector being launched.

Each connector is a separate program. A connector can read whatever the signed-in macOS user and macOS privacy permissions allow it to read. Review a connector's own privacy documentation and source before enabling it.

## Data Bridgeport Stores

Bridgeport stores its configuration and generated client files under `~/.config/bridgeport`. These files can contain:

- The Bridgeport bearer token.
- OAuth client registrations and access tokens.
- Connector commands, arguments, source paths, and environment references.
- Generated MCP client and cloud-connector definitions, including authorization values.
- Cloudflare tunnel metadata and local log paths. Cloudflare credentials remain in the configured credentials file rather than the Bridgeport app bundle.

Bridgeport creates the configuration directory with mode `0700` and sensitive generated files with mode `0600`. The files are not encrypted by Bridgeport. macOS disk encryption, account security, backups, and any synchronized storage remain the user's responsibility.

## Network Activity

Bridgeport listens on `127.0.0.1` by default. It sends MCP requests and responses only between a client and the connector selected by that request.

Remote traffic occurs only when the user configures a public base URL and tunnel, enables Cloudflare support, and marks a connector **Public**. That traffic passes through the user's Cloudflare account and the remote MCP provider or client the user configured. Those services have their own privacy policies and logs.

Bridgeport invokes `cloudflared` and the 1Password CLI when those integrations are enabled. It also opens project documentation and issue links in the default browser when the user selects those menu items. Bridgeport does not otherwise send data to the maintainer.

## Logs and Retention

Bridgeport logs operational status, connector names, source paths, endpoints, and process errors to stderr or the configured LaunchAgent logs. It does not intentionally log MCP request bodies, bearer tokens, or resolved connector secrets. Connector subprocesses and `cloudflared` maintain their own logs and may have different behavior.

Data remains until the user removes it. `bridgeport --daemon-uninstall` removes the installed daemon binary and its LaunchAgent, but it intentionally leaves configuration and generated client files in `~/.config/bridgeport` so an uninstall does not silently destroy user settings. Remove that directory manually only after confirming it is no longer needed.

## Privacy Questions

Use the repository issue tracker for non-sensitive questions. For a concern that includes configuration, credentials, or private connector data, use the private security-reporting process in [SECURITY.md](SECURITY.md).
