# Agent Subsystem Spec

## Purpose
Orchestrate chat loops, tool dispatch, and compaction for autonomous operation.

## Key Features
- Tool call parsing/dispatch
- Chat loop with streaming
- Memory compaction
- Error recovery
- Subagent spawning

## Acceptance Criteria
- Chat loops complete successfully
- Tools dispatched and executed
- Streaming works
- Memory managed efficiently
- Tests pass for loops

## Implementation Notes
- Port dispatcher logic
- Async tool execution
- JSON parsing for calls
- Loop state management