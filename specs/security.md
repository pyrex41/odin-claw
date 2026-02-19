# Security Subsystem Spec

## Purpose
Enforce sandboxing, secrets, auditing, and pairing for secure operation.

## Key Features
- Sandboxing backends (Landlock, Firejail, Bubblewrap, Docker)
- Secret encryption (ChaCha20-Poly1305)
- Pairing for bearer tokens
- Audit logging with retention
- Resource limits (CPU/memory)

## Acceptance Criteria
- Sandbox auto-detects and applies
- Secrets encrypted/decrypted correctly
- Pairing required for access
- Audits logged and retained
- No security bypasses
- Tests pass for enforcement

## Implementation Notes
- Port sandbox backends
- Crypto for secrets
- HTTP pairing endpoint
- Log rotation
- System resource monitoring