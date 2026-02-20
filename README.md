# NullClaw

AI assistant runtime written in Odin, inspired by the Zig implementation.

## Features

- **Multi-Provider Support**: OpenAI, Anthropic, xAI, Ollama, and 30+ OpenAI-compatible providers
- **10 Built-in Tools**: shell, file_read, file_write, file_edit, file_append, git, http_request, memory_store, memory_recall, memory_forget
- **Multiple Channels**: CLI, Telegram, Slack, Discord
- **LMDB Backend**: Fast local memory storage
- **Gateway Server**: HTTP server with CORS, pairing, rate limiting
- **Security**: ChaCha20-Poly1305 encryption, audit logging, path sandboxing

## Installation

```bash
# Compile C helper for libcurl (one-time)
cc -c src/curl_helpers.c -o src/curl_helpers.o

# Build
odin build src -out:nullclaw
```

## Configuration

Create `~/.nullclaw/config.json`:

```json
{
  "providers": {
    "default_provider": "openai",
    "default_model": "gpt-4o",
    "openai_api_key": "sk-..."
  },
  "tools": {
    "workspace_path": "/tmp"
  },
  "channels": {
    "telegram_api_key": "..."
  }
}
```

Or use environment variables:
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `XAI_API_KEY`
- `NULLCLAW_PROVIDERS_DEFAULT_PROVIDER`

## Commands

| Command | Description |
|---------|-------------|
| `nullclaw agent` | Start the AI agent loop |
| `nullclaw gateway` | Start HTTP gateway server |
| `nullclaw channel` | Manage messaging channels |
| `nullclaw status` | Show system status |
| `nullclaw doctor` | Run diagnostics |
| `nullclaw onboard` | Initial setup wizard |
| `nullclaw models` | List available models |
| `nullclaw help` | Show help |

## Providers

- **OpenAI**: gpt-4o, gpt-4-turbo, gpt-3.5-turbo
- **Anthropic**: claude-sonnet-4, claude-opus-4
- **xAI**: grok-2, grok-beta
- **Ollama**: llama3, mistral, codellama (local)
- **OpenAI-Compatible**: Groq, DeepSeek, LM Studio, Vercel, Mistral, Cohere, Together, Perplexity, NVIDIA NIM, Venice, Zen/OpenCode

## Tools

All tools support sandboxed execution with path validation:

- `shell` - Execute shell commands
- `file_read` - Read files
- `file_write` - Write files
- `file_edit` - Edit files (replace text)
- `file_append` - Append to files
- `git` - Git operations (status, commit, push, pull)
- `http_request` - Make HTTP requests
- `memory_store` - Store in memory DB
- `memory_recall` - Search memory
- `memory_forget` - Delete from memory

## Testing

```bash
odin test src -all-packages
```

## License

MIT
