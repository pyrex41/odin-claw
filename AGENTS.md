# OdinClaw - Operational Guide

## Build & Run

```bash
# Compile C helper for libcurl (one-time, or after changing curl_helpers.c)
cc -c src/curl_helpers.c -o src/curl_helpers.o

# Build
odin build src -out:odin-claw -o:size
strip odin-claw

# Test
odin test src/ -all-packages

# Format
odinfmt -w src/
```

## Commands

```bash
# Interactive agent (uses configured provider)
./odin-claw agent

# Single message
./odin-claw agent -m "Hello"

# Override provider/model
./odin-claw agent --provider ollama --model llama3.2 -m "Hello"

# Start gateway HTTP server
./odin-claw gateway
./odin-claw gateway --port 9090 --host 0.0.0.0

# List channels
./odin-claw channel list

# Start channel loop (CLI or Telegram depending on config)
./odin-claw channel start

# Help
./odin-claw help
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | OpenAI API key |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `XAI_API_KEY` | xAI/Grok API key |
| `NULLCLAW_PROVIDERS_DEFAULT_PROVIDER` | Provider: openai, anthropic, ollama, xai, compatible |
| `NULLCLAW_PROVIDERS_DEFAULT_MODEL` | Model name override |
| `NULLCLAW_PROVIDERS_OLLAMA_ENDPOINT` | Ollama endpoint (default: http://localhost:11434) |
| `NULLCLAW_TELEGRAM_API_KEY` | Telegram bot token |
| `NULLCLAW_SLACK_WEBHOOK_URL` | Slack webhook URL |
| `NULLCLAW_DISCORD_TOKEN` | Discord bot token |
| `NULLCLAW_CONFIG_PATH` | Config file path (default: ~/.odin-claw/config.json) |

## Architecture

### Subsystems (all implemented)
- **HTTP** (`http.odin`) - libcurl FFI + C helpers for ARM64 ABI compatibility
- **Providers** (`providers.odin`) - OpenAI, Anthropic, Ollama, OpenAI-Compatible, Mock
- **Agent** (`agent.odin`) - Chat loop, tool dispatch, memory compaction, retry
- **Tools** (`tools.odin`) - shell, file_read, file_write, file_edit, file_append, git, http_request, memory_store, memory_recall, memory_forget
- **Memory** (`memory.odin`) - In-memory store with JSON snapshot export/import
- **Gateway** (`gateway.odin`) - TCP server via core:net, request routing, pairing, CORS
- **Channels** (`channels.odin`) - CLI (bidirectional), Telegram (long-polling), Slack (webhook send), Discord (REST send)
- **Security** (`security.odin`) - ChaCha20-Poly1305 encryption, audit log to file, sandbox path checks
- **Peripherals** (`peripherals.odin`) - Serial device vtable, graceful non-Linux handling
- **Config** (`config.odin`) - JSON config + env var overrides
- **Runtime** (`runtime.odin`) - Native process execution via libc system()

### Key Patterns
- Interfaces use vtable structs with proc pointers
- Errors are custom enums
- Memory: builders returned as strings (caller frees via delete)
- Tests use `testing` package with `expect`
- libcurl uses C wrappers (`curl_helpers.c`) because ARM64 varargs ABI differs from regular args
