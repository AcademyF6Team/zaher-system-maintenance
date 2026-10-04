# Security Policy

## Supported Versions
| Version | Supported |
|---------|-----------|
| 3.0.x   | ✅        |
| 2.x     | ❌        |

## Reporting a Vulnerability

Please **do not** open a public issue for security bugs.
Email: security@example.com

Include:
- Version
- Windows build
- Steps to reproduce
- Impact
- Suggested fix (optional)

We aim to respond within 72 hours.

## Threat Model

The tool:
- Runs with administrator privileges **only when needed**.
- Never connects to the internet.
- Never downloads or executes remote code.
- Never modifies user files outside `%TEMP%` cleanup (with consent).
- Creates restore points and backups before changes.
- Logs every action to `audit.log`.

If you find behavior violating the above, report immediately.