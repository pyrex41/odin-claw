# Gateway Subsystem Spec

## Purpose
HTTP server for webhooks, pairing, and API access.

## Key Features
- Webhook endpoints for channels
- Pairing authentication (6-digit codes)
- Rate limiting and idempotency
- CORS and security headers
- Health checks

## Acceptance Criteria
- Webhooks received/processed
- Pairing generates tokens
- Public bind refused without tunnel
- Tests pass for endpoints

## Implementation Notes
- HTTP server (Odin std.net)
- Route handling
- Token validation
- Request parsing