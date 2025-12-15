# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2025-12-15

### Added

- **Unified Deployment System**: New `deploy-windows.bat` and `file-monitor-mac.sh` for streamlined installation.
- **Background Services**: All monitors now install as native background services (Task Scheduler / LaunchAgent).
- **Auto-Update**: Windows clients now check for updates from the Admin PC and self-restart.
- **Admin Setup Script**: `setup-admin-pc.bat` for one-click Admin PC configuration.
- **Documentation**: Comprehensive README and Deployment Walkthrough.

### Changed

- **Silent Operation**: Removed all debug console output for true background operation.
- **Port Configuration**: Standardized Webhook to port 5678 and Update Server to port 8888.
- **Website**: Simplified `index.html` to focus on copy-paste commands.

### Fixed

- **Parsec Detection**: Fixed log path resolution on Windows when running as SYSTEM.
- **File Events**: Fixed `ArrayList` bug preventing some file deletion events from sending.
- **Duplicate Logs**: Fixed double-entry bug in Admin Parsec monitor.

## [1.0.0] - 2025-12-14

### Added

- Initial release of Windows `file-monitor.ps1`.
- Initial release of Mac `file-monitor-mac.sh`.
- Basic n8n integration.
