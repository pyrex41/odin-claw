# Runtime Subsystem Spec

## Purpose
Abstract execution environments (native, Docker, WASM) for sandboxing tools.

## Key Features
- Runtime selection (native/full, Docker/containerized, WASM/limited)
- Resource limits (memory, CPU, disk)
- Filesystem/network access control
- Storage path management

## Acceptance Criteria
- Native runtime allows full access
- Docker runtime isolates properly
- WASM runtime enforces limits
- Startup <2ms
- Tests pass for isolation

## Implementation Notes
- Port vtable to Odin
- Docker API integration if used
- WASM runtime (e.g., wasmtime binding)
- Path resolution