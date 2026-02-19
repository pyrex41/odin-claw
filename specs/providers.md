# Providers Subsystem Spec

## Purpose
Interface with AI models (OpenAI, Anthropic, Ollama, etc.) for chat, tool calling, and streaming. Support 22+ providers including OpenAI, Anthropic, Ollama, Gemini, etc.

## Key Features
- Chat with structured requests/responses (text, tool calls, usage)
- Streaming support via callbacks
- Tool call parsing (native JSON and XML formats)
- API key management (config/env with scrubbing)
- Error handling and retry logic
- Compatible providers for OpenAI-like APIs

## Acceptance Criteria
- Support all 22+ providers from Zig version
- Maintain API compatibility (ChatRequest/ChatResponse types)
- Tool calls work for native and XML formats
- Streaming callbacks function correctly
- Startup time <2ms (no heavy initialization)
- Memory usage <1MB total for subsystem
- Tests pass for all providers

## Implementation Notes
- Port vtable interface from Zig to Odin traits/structs
- Maintain JSON parsing for requests/responses
- HTTP client for API calls (use Odin's std.net or external lib)
- ChaCha20-Poly1305 for secrets if needed
- No external dependencies beyond Odin stdlib