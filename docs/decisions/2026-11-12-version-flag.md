---
id: 2026-11-12-version-flag
status: implemented
topic: cli
prs: [18]
---
# `stenographr --version`

- **Decision:** the CLI answers `--version`, so it fits the standard hyperbeam verbs.
- **Why:** hyperbeam's `version` verb needs something to ask. `--help` and the README install line cover help and install.
- **Rejected:** a `help` or `install` subcommand.
