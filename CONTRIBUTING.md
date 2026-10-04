# Contributing

## Code Style
- Use PowerShell 5.1 compatible syntax.
- Follow `Verb-Noun` naming.
- Add `try/catch` around any external call.
- Never add network calls.
- Never add code that runs without explicit user consent.

## Before PR
1. Test in a Windows 10 + Windows 11 VM.
2. Run `-AuditOnly` first.
3. Verify rollback works for any hardening change.
4. Update `CHANGELOG.md`.

## Commit Style
`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`