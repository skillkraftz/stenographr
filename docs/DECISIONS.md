# Decisions

Newest first: date, decision, why, what was rejected. SPEC.md remains the behaviour spec.

## 2026-11-12: `stenographr --version`
Added so the CLI answers the standard hyperbeam verbs. Rejected: a `help` or `install` subcommand (`--help` and the README install line are enough).

## 2026-11-09: CPU/RAM cost not addressed yet
The CPU run used 4.9 GB of RAM, against about 800 MB for a comparable tool. Why: not a problem yet. Deferred.

## 2026-11-09: No corrections file for mis-heard names
Why: transcripts mostly go to AI, which infers the meaning. Rejected: a corrections file.
