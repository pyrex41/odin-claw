# Config Subsystem Spec

## Purpose
JSON config loading/merging for all subsystems.

## Key Features
- Hierarchical config (global + per-subsystem)
- Environment variable overrides
- Validation and defaults
- 30+ config types/structs

## Acceptance Criteria
- JSON parsed correctly
- Overrides applied
- Validation prevents invalid configs
- Tests pass for loading

## Implementation Notes
- JSON parsing
- Struct deserialization
- Path resolution (~/.nullclaw)
- Merge logic