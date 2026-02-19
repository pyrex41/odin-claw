# Memory Subsystem Spec

## Purpose
Persistent storage for conversation history, knowledge, and embeddings. Hybrid vector + FTS5 search.

## Key Features
- SQLite backend with FTS5 and vector BLOBs
- Hybrid search (keyword + cosine similarity)
- Embedding providers (OpenAI, custom)
- Automatic hygiene (purge stale data)
- Snapshots for migration
- Multiple backends (SQLite, Markdown, none)

## Acceptance Criteria
- Hybrid search returns relevant results
- Embeddings stored/retrieved correctly
- Hygiene runs automatically
- Snapshots export/import full state
- Memory usage <1MB for subsystem
- Tests pass for all operations

## Implementation Notes
- Port SQLite FTS5/vector logic to Odin
- Cosine similarity math
- JSON for snapshots
- Optional embedding providers
- Thread-safe operations