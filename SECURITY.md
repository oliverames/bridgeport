# Security Policy

Bridgeport runs local MCP connectors with the permissions of the signed-in macOS user and can make selected connectors reachable through a Cloudflare Tunnel. Security reports are welcome, especially for authentication bypasses, unintended public exposure, unsafe connector discovery, credential leakage, or command execution outside the connector configuration a user approved.

## Supported Versions

Security fixes are provided for the latest published release. Older releases may not receive backports.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting from the repository's **Security** tab. Do not include exploit details, tokens, connector output, or private configuration in a public issue. If private reporting is unavailable, contact the maintainer through the GitHub profile and ask for a private reporting channel without sending sensitive details.

Include the affected Bridgeport version, macOS version, reproduction steps using synthetic data where possible, and the security impact. Reports will be acknowledged as soon as practical. A fix and disclosure timeline will be coordinated after the issue is reproduced.

## Deployment Guidance

- Keep Bridgeport bound to `127.0.0.1` unless another bind address is explicitly required.
- Leave query-string token authentication disabled. Tokens in URLs can appear in browser history, proxy logs, analytics, and screenshots.
- Expose only the connectors that need remote access. A connector's **Public** toggle is an authorization boundary, not a discoverability preference.
- Put public hostnames behind Cloudflare Access or an equivalent identity-aware control, plus rate limits and path/method restrictions.
- Treat every imported or mirrored connector as executable code. Review its command, arguments, environment references, and source before enabling it.
- Rotate the Bridgeport token after suspected disclosure. Review and rotate any connector-specific credentials separately.
- Keep `~/.config/bridgeport` and Cloudflare credential files private to the owning macOS account.

The detailed trust boundaries, controls, and non-goals are documented in [the threat model](docs/THREAT_MODEL.md).
