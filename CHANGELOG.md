## Changelog

## [3.0.0] - 2026-03-16

### Added
- Modular framework for controlling Windows Update, reboot behavior, maintenance and related components on Windows 11.
- Built-in profiles: `SafeDesktop`, `ControlledDesktop`, `WorkstationStable`, `KioskLab`, `ExtremeAirgapped`, `Custom`.
- State snapshot system (registry, services, tasks, ACL, files) with `state.json` and `.reg` backups.
- `Apply`, `Restore`, `Status` actions with detailed logging and operation summary.
- Importable/exportable JSON presets to replicate configurations.

### Changed
- Code structure by functional area (modules) and more robust error handling.

### Security
- `DefenderControl` option with conservative modes to minimize security impact.
- Extreme measures (rename of `UsoClient.exe`, `ServiceAclLockdown`) clearly marked as advanced/use-with-caution options.

---

[3.0.0]: https://github.com/standardbus/win11-update-control/releases/tag/v3.0.0


