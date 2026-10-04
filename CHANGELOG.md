# Changelog

All notable changes to Zaher System Maintenance.

## [3.0.0] - 2026-XX-XX

### Added
- Secure Boot, TPM, BitLocker audit
- LSASS Protection (RunAsPPL) hardening + rollback
- UAC level inspection
- Defender exclusions audit
- Hosts file audit
- SMB Shares audit
- Open ports audit
- Password policy audit
- PowerShell Execution Policy audit
- JSON report export
- Progress bar during collection
- Separate `audit.log`
- `-Version` flag
- Rollback support for all hardening operations

### Changed
- Renamed project from `Zahar` to `Zaher`
- Improved Baseline comparison (full state)
- Better Wi-Fi password validation
- Cleaner UI banner

### Fixed
- Lock file no longer deleted by non-owner instance
- Scheduled task audit no longer fails on broken tasks
- SMB1 rollback verified
- Restore point 24h limit properly detected

## [2.1.0] - 2026-XX-XX
- Initial public release (as Zahar).