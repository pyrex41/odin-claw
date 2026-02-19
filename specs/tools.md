# Tools Subsystem Spec

## Purpose
Extend LLM capabilities via function calling (shell, file I/O, HTTP, etc.). Support 18+ tools including shell, file operations, memory, browser, etc.

## Key Features
- Tool execution with JSON args
- Schema generation for LLM specs
- Security: workspace scoping, allowed paths
- Error handling and output formatting
- Subagent delegation
- Cron scheduling

## Acceptance Criteria
- All 18+ tools functional
- JSON args parsed/executed correctly
- Security boundaries enforced
- Output formatted for LLM feedback
- Tests pass for execution

## Implementation Notes
- Port vtable to Odin
- JSON parsing for args
- Process spawning for shell/tools
- Path validation
- Result serialization