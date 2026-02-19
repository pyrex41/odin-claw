const std = @import("std");
const json_util = @import("../json_util.zig");
const http_util = @import("../http_util.zig");

// Re-export all provider sub-modules
pub const anthropic = @import("anthropic.zig");
pub const openai = @import("openai.zig");
pub const ollama = @import("ollama.zig");
pub const gemini = @import("gemini.zig");
pub const openrouter = @import("openrouter.zig");
pub const compatible = @import("compatible.zig");
pub const reliable = @import("reliable.zig");
pub const router = @import("router.zig");
pub const sse = @import("sse.zig");
pub const claude_cli = @import("claude_cli.zig");
pub const codex_cli = @import("codex_cli.zig");

// ════════════════════════════════════════════════════════════════════════════
// Core Types
// ════════════════════════════════════════════════════════════════════════════

/// Level of detail for image processing.
pub const ImageDetail = enum {
    auto,
    low,
    high,

    pub fn toSlice(self: ImageDetail) []const u8 {
        return switch (self) {
            .auto => "auto",
            .low => "low",
            .high => "high",
        };
    }
};

/// A single content part in a multimodal message.
pub const ContentPart = union(enum) {
    text: []const u8,
    image_url: ImageUrl,
    image_base64: ImageBase64,

    pub const ImageUrl = struct {
        url: []const u8,
        detail: ImageDetail = .auto,
    };

    pub const ImageBase64 = struct {
        data: []const u8,
        media_type: []const u8,
    };
};

/// Create a text content part.
pub fn makeTextPart(text: []const u8) ContentPart {
    return .{ .text = text };
}

/// Create an image URL content part.
pub fn makeImageUrlPart(url: []const u8) ContentPart {
    return .{ .image_url = .{ .url = url } };
}

/// Create a base64-encoded image content part.
pub fn makeBase64ImagePart(data: []const u8, media_type: []const u8) ContentPart {
    return .{ .image_base64 = .{ .data = data, .media_type = media_type } };
}

/// Roles a message can have in a conversation.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toSlice(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }

    pub fn fromSlice(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }
};

/// A single message in a conversation.
pub const ChatMessage = struct {
    role: Role,
    content: []const u8,
    /// Optional name (for tool results).
    name: ?[]const u8 = null,
    /// Tool call ID this message responds to.
    tool_call_id: ?[]const u8 = null,
    /// Optional multimodal content parts (images, etc.). When set, providers
    /// serialize these instead of the plain `content` field.
    content_parts: ?[]const ContentPart = null,

    pub fn system(content: []const u8) ChatMessage {
        return .{ .role = .system, .content = content };
    }

    pub fn user(content: []const u8) ChatMessage {
        return .{ .role = .user, .content = content };
    }

    pub fn assistant(content: []const u8) ChatMessage {
        return .{ .role = .assistant, .content = content };
    }

    pub fn toolMsg(content: []const u8, tool_call_id: []const u8) ChatMessage {
        return .{ .role = .tool, .content = content, .tool_call_id = tool_call_id };
    }
};

/// A tool call requested by the LLM.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Token usage stats from a provider response.
pub const TokenUsage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
};

/// An LLM response that may contain text, tool calls, or both.
pub const ChatResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    usage: TokenUsage = .{},
    model: []const u8 = "",
    /// Optional reasoning/thinking content from models that support it (e.g. Claude extended thinking).
    reasoning_content: ?[]const u8 = null,

    /// True when the LLM wants to invoke at least one tool.
    pub fn hasToolCalls(self: ChatResponse) bool {
        return self.tool_calls.len > 0;
    }

    /// Convenience: return text content or empty string.
    pub fn contentOrEmpty(self: ChatResponse) []const u8 {
        return self.content orelse "";
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Streaming Types
// ════════════════════════════════════════════════════════════════════════════

/// A single chunk of streamed output.
pub const StreamChunk = struct {
    delta: []const u8,
    is_final: bool,
    token_count: u32,

    /// Create a text delta chunk with estimated token count.
    pub fn textDelta(text: []const u8) StreamChunk {
        return .{
            .delta = text,
            .is_final = false,
            .token_count = @intCast((text.len + 3) / 4),
        };
    }

    /// Create a final (end-of-stream) chunk.
    pub fn finalChunk() StreamChunk {
        return .{
            .delta = "",
            .is_final = true,
            .token_count = 0,
        };
    }
};

/// Callback invoked for each streaming chunk.
pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: StreamChunk) void;

/// Result of a streaming chat call (accumulated after stream completes).
pub const StreamChatResult = struct {
    content: ?[]const u8 = null,
    usage: TokenUsage = .{},
    model: []const u8 = "",
};

/// Tool specification for function-calling APIs.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema for the tool's parameters.
    parameters_json: []const u8 = "{}",
};

/// Request payload for provider chat calls.
pub const ChatRequest = struct {
    messages: []const ChatMessage,
    model: []const u8 = "",
    temperature: f64 = 0.7,
    max_tokens: u32 = 4096,
    tools: ?[]const ToolSpec = null,
};

/// A single tool result message in a conversation.
pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,
};

/// Kind discriminator for ConversationMessage.
pub const ConversationMessageKind = enum { chat, assistant_tool_calls, tool_results };

/// A conversation message that can be a plain chat, assistant tool calls, or tool results.
pub const ConversationMessage = union(ConversationMessageKind) {
    chat: ChatMessage,
    assistant_tool_calls: struct {
        text: []const u8,
        tool_calls: []const ToolCall,
    },
    tool_results: []const ToolResultMessage,
};

// ════════════════════════════════════════════════════════════════════════════
// Provider Interface (vtable-based polymorphism)
// ════════════════════════════════════════════════════════════════════════════

/// Provider interface. Zig equivalent of ZeroClaw's `trait Provider`.
/// Uses vtable-based polymorphism for runtime dispatch.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Simple one-shot chat: system prompt + user message.
        chatWithSystem: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            system_prompt: ?[]const u8,
            message: []const u8,
            model: []const u8,
            temperature: f64,
        ) anyerror![]const u8,

        /// Structured chat returning ChatResponse (supports tool calls).
        chat: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
            model: []const u8,
            temperature: f64,
        ) anyerror!ChatResponse,

        /// Whether this provider supports native tool calls.
        supportsNativeTools: *const fn (ptr: *anyopaque) bool,

        /// Provider name for diagnostics.
        getName: *const fn (ptr: *anyopaque) []const u8,

        /// Clean up resources.
        deinit: *const fn (ptr: *anyopaque) void,

        /// Optional: pre-warm connection. Default: no-op.
        warmup: ?*const fn (ptr: *anyopaque) void = null,
        /// Optional: native function calling. Default: delegates to chat().
        chat_with_tools: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: ChatRequest) anyerror!ChatResponse = null,
        /// Optional: returns true if provider supports streaming. Default: false.
        supports_streaming: ?*const fn (ptr: *anyopaque) bool = null,
        /// Optional: streaming chat. Default: null (falls back to chat() with single chunk).
        stream_chat: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
            model: []const u8,
            temperature: f64,
            callback: StreamCallback,
            callback_ctx: *anyopaque,
        ) anyerror!StreamChatResult = null,
    };

    pub fn chatWithSystem(
        self: Provider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ![]const u8 {
        return self.vtable.chatWithSystem(self.ptr, allocator, system_prompt, message, model, temperature);
    }

    pub fn chat(
        self: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) !ChatResponse {
        return self.vtable.chat(self.ptr, allocator, request, model, temperature);
    }

    pub fn supportsNativeTools(self: Provider) bool {
        return self.vtable.supportsNativeTools(self.ptr);
    }

    pub fn getName(self: Provider) []const u8 {
        return self.vtable.getName(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        return self.vtable.deinit(self.ptr);
    }

    /// Warm up the provider connection. No-op if not implemented.
    pub fn warmup(self: Provider) void {
        if (self.vtable.warmup) |f| f(self.ptr);
    }

    /// Returns true if provider supports streaming.
    pub fn supportsStreaming(self: Provider) bool {
        if (self.vtable.supports_streaming) |f| return f(self.ptr);
        return false;
    }

    /// Chat with native tool support. Falls back to regular chat() if not implemented.
    pub fn chatWithTools(self: Provider, allocator: std.mem.Allocator, req: ChatRequest) !ChatResponse {
        if (self.vtable.chat_with_tools) |f| return f(self.ptr, allocator, req);
        return self.chat(allocator, req, req.model, req.temperature);
    }

    /// Streaming chat. If vtable slot is null, falls back to chat() and emits a single chunk + final.
    pub fn streamChat(
        self: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) !StreamChatResult {
        if (self.vtable.stream_chat) |f| {
            return f(self.ptr, allocator, request, model, temperature, callback, callback_ctx);
        }
        // Fallback: blocking chat() → single chunk + final
        const response = try self.chat(allocator, request, model, temperature);
        if (response.content) |content| {
            if (content.len > 0) {
                callback(callback_ctx, StreamChunk.textDelta(content));
            }
        }
        callback(callback_ctx, StreamChunk.finalChunk());
        return .{
            .content = response.content,
            .usage = response.usage,
            .model = response.model,
        };
    }
};

/// Comptime check that a type correctly implements the Provider interface.
pub fn assertProviderInterface(comptime T: type) void {
    if (!@hasDecl(T, "provider")) @compileError(@typeName(T) ++ " missing provider() method");
    if (!@hasDecl(T, "vtable")) @compileError(@typeName(T) ++ " missing vtable constant");
    const vt = T.vtable;
    _ = vt.chatWithSystem;
    _ = vt.chat;
    _ = vt.supportsNativeTools;
    _ = vt.getName;
    _ = vt.deinit;
}

// ════════════════════════════════════════════════════════════════════════════
// Secret Scrubbing
// ════════════════════════════════════════════════════════════════════════════

const MAX_API_ERROR_CHARS: usize = 200;

fn isSecretChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':';
}

fn tokenEnd(input: []const u8, from: usize) usize {
    var end = from;
    for (input[from..]) |c| {
        if (isSecretChar(c)) {
            end += 1;
        } else {
            break;
        }
    }
    return end;
}

/// Scrub known secret-like token prefixes from text.
/// Redacts tokens with prefixes like `sk-`, `xoxb-`, `ghp_`, etc.
pub fn scrubSecretPatterns(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const prefixes = [_][]const u8{
        "sk-",  "xoxb-", "xoxp-", "ghp_",
        "gho_", "ghs_",  "ghu_",  "glpat-",
        "AKIA", "pypi-", "npm_",  "shpat_",
    };
    const redacted = "[REDACTED]";

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // 1. Check key-value patterns: api_key=VALUE, token=VALUE, etc.
        if (matchKeyValueSecret(input, i)) |kv| {
            // Keep key + separator, redact the value (show first 4 chars)
            try result.appendSlice(allocator, input[i..kv.value_start]);
            const val = input[kv.value_start..kv.value_end];
            if (val.len > 4) {
                try result.appendSlice(allocator, val[0..4]);
            }
            try result.appendSlice(allocator, redacted);
            i = kv.value_end;
            continue;
        }

        // 2. Check "bearer TOKEN" (case-insensitive)
        if (matchBearerToken(input, i)) |bt| {
            try result.appendSlice(allocator, input[i .. i + bt.prefix_len]);
            const val = input[i + bt.prefix_len .. bt.end];
            if (val.len > 4) {
                try result.appendSlice(allocator, val[0..4]);
            }
            try result.appendSlice(allocator, redacted);
            i = bt.end;
            continue;
        }

        // 3. Check prefix-based tokens
        var matched = false;
        for (prefixes) |prefix| {
            if (i + prefix.len <= input.len and std.mem.eql(u8, input[i..][0..prefix.len], prefix)) {
                const content_start = i + prefix.len;
                const end = tokenEnd(input, content_start);
                if (end > content_start) {
                    try result.appendSlice(allocator, redacted);
                    i = end;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

const KeyValueMatch = struct { value_start: usize, value_end: usize };

/// Match patterns like `api_key=VALUE`, `token=VALUE`, `password: VALUE`, `secret=VALUE`.
fn matchKeyValueSecret(input: []const u8, pos: usize) ?KeyValueMatch {
    const keywords = [_][]const u8{
        "api_key", "api-key",    "apikey",
        "token",   "password",   "passwd",
        "secret",  "api_secret", "access_key",
    };
    for (keywords) |kw| {
        if (pos + kw.len >= input.len) continue;
        if (!eqlLowercase(input[pos..][0..kw.len], kw)) continue;
        // Check separator after keyword: `=`, `:`, `= `, `: `
        var sep_end = pos + kw.len;
        if (sep_end < input.len and (input[sep_end] == '=' or input[sep_end] == ':')) {
            sep_end += 1;
            // Skip optional space after separator
            while (sep_end < input.len and input[sep_end] == ' ') sep_end += 1;
            // Skip optional quotes
            var quote: u8 = 0;
            if (sep_end < input.len and (input[sep_end] == '"' or input[sep_end] == '\'')) {
                quote = input[sep_end];
                sep_end += 1;
            }
            const value_start = sep_end;
            var value_end = value_start;
            if (quote != 0) {
                // Read until closing quote
                while (value_end < input.len and input[value_end] != quote) value_end += 1;
                if (value_end < input.len) value_end += 1; // skip closing quote
            } else {
                value_end = tokenEnd(input, value_start);
            }
            if (value_end > value_start) {
                return .{ .value_start = value_start, .value_end = value_end };
            }
        }
    }
    return null;
}

const BearerMatch = struct { prefix_len: usize, end: usize };

/// Match "Bearer TOKEN" or "bearer TOKEN" pattern.
fn matchBearerToken(input: []const u8, pos: usize) ?BearerMatch {
    const bearer_variants = [_][]const u8{ "Bearer ", "bearer ", "BEARER " };
    for (bearer_variants) |prefix| {
        if (pos + prefix.len <= input.len and std.mem.eql(u8, input[pos..][0..prefix.len], prefix)) {
            const token_start = pos + prefix.len;
            const end = tokenEnd(input, token_start);
            if (end > token_start) {
                return .{ .prefix_len = prefix.len, .end = end };
            }
        }
    }
    return null;
}

/// Case-insensitive comparison (input can be mixed case, kw is lowercase).
fn eqlLowercase(input: []const u8, kw: []const u8) bool {
    if (input.len != kw.len) return false;
    for (input, kw) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

/// Maximum tool output length before truncation.
const MAX_TOOL_OUTPUT_CHARS: usize = 10_000;

/// Scrub credentials from tool execution output and truncate if too long.
/// Returns an owned slice. Caller must free.
pub fn scrubToolOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // First truncate if too long
    const truncated = if (input.len > MAX_TOOL_OUTPUT_CHARS) blk: {
        const suffix = "\n[output truncated]";
        var buf = try allocator.alloc(u8, MAX_TOOL_OUTPUT_CHARS + suffix.len);
        @memcpy(buf[0..MAX_TOOL_OUTPUT_CHARS], input[0..MAX_TOOL_OUTPUT_CHARS]);
        @memcpy(buf[MAX_TOOL_OUTPUT_CHARS..], suffix);
        break :blk buf;
    } else try allocator.dupe(u8, input);
    defer allocator.free(truncated);

    // Then scrub secrets
    return scrubSecretPatterns(allocator, truncated);
}

/// Sanitize API error text by scrubbing secrets and truncating length.
pub fn sanitizeApiError(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const scrubbed = try scrubSecretPatterns(allocator, input);

    if (scrubbed.len <= MAX_API_ERROR_CHARS) {
        return scrubbed;
    }

    // Truncate
    var truncated = try allocator.alloc(u8, MAX_API_ERROR_CHARS + 3);
    @memcpy(truncated[0..MAX_API_ERROR_CHARS], scrubbed[0..MAX_API_ERROR_CHARS]);
    @memcpy(truncated[MAX_API_ERROR_CHARS..][0..3], "...");
    allocator.free(scrubbed);
    return truncated;
}

// ════════════════════════════════════════════════════════════════════════════
// API Key Resolution
// ════════════════════════════════════════════════════════════════════════════

/// Resolve API key for a provider from config and environment variables.
///
/// Resolution order:
/// 1. Explicitly provided `api_key` parameter (trimmed, filtered if empty)
/// 2. Provider-specific environment variable
/// 3. Generic fallback variables (`NULLCLAW_API_KEY`, `API_KEY`)
pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    api_key: ?[]const u8,
) !?[]u8 {
    // 1. Explicit key
    if (api_key) |key| {
        const trimmed = std.mem.trim(u8, key, " \t\r\n");
        if (trimmed.len > 0) {
            return try allocator.dupe(u8, trimmed);
        }
    }

    // 2. Provider-specific env vars
    const env_candidates = providerEnvCandidates(provider_name);
    for (env_candidates) |env_var| {
        if (env_var.len == 0) break;
        if (std.process.getEnvVarOwned(allocator, env_var)) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) {
                if (trimmed.ptr != value.ptr or trimmed.len != value.len) {
                    const duped = try allocator.dupe(u8, trimmed);
                    allocator.free(value);
                    return duped;
                }
                return value;
            }
            allocator.free(value);
        } else |_| {}
    }

    // 3. Generic fallbacks
    const fallbacks = [_][]const u8{ "NULLCLAW_API_KEY", "API_KEY" };
    for (fallbacks) |env_var| {
        if (std.process.getEnvVarOwned(allocator, env_var)) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) {
                if (trimmed.ptr != value.ptr or trimmed.len != value.len) {
                    const duped = try allocator.dupe(u8, trimmed);
                    allocator.free(value);
                    return duped;
                }
                return value;
            }
            allocator.free(value);
        } else |_| {}
    }

    return null;
}

fn providerEnvCandidates(name: []const u8) [3][]const u8 {
    if (std.mem.eql(u8, name, "anthropic")) return .{ "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "" };
    if (std.mem.eql(u8, name, "openrouter")) return .{ "OPENROUTER_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "openai")) return .{ "OPENAI_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "gemini") or std.mem.eql(u8, name, "google") or std.mem.eql(u8, name, "google-gemini")) return .{ "GEMINI_API_KEY", "GOOGLE_API_KEY", "" };
    if (std.mem.eql(u8, name, "groq")) return .{ "GROQ_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "mistral")) return .{ "MISTRAL_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "deepseek")) return .{ "DEEPSEEK_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "xai") or std.mem.eql(u8, name, "grok")) return .{ "XAI_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "together") or std.mem.eql(u8, name, "together-ai")) return .{ "TOGETHER_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "fireworks") or std.mem.eql(u8, name, "fireworks-ai")) return .{ "FIREWORKS_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "perplexity")) return .{ "PERPLEXITY_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "cohere")) return .{ "COHERE_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "venice")) return .{ "VENICE_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "moonshot") or std.mem.eql(u8, name, "kimi")) return .{ "MOONSHOT_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "nvidia") or std.mem.eql(u8, name, "nvidia-nim") or std.mem.eql(u8, name, "build.nvidia.com")) return .{ "NVIDIA_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "astrai")) return .{ "ASTRAI_API_KEY", "", "" };
    if (std.mem.eql(u8, name, "lmstudio") or std.mem.eql(u8, name, "lm-studio")) return .{ "", "", "" };
    return .{ "", "", "" };
}

// ════════════════════════════════════════════════════════════════════════════
// Provider Factory
// ════════════════════════════════════════════════════════════════════════════

pub const ProviderKind = enum {
    anthropic_provider,
    openai_provider,
    openrouter_provider,
    ollama_provider,
    gemini_provider,
    compatible_provider,
    claude_cli_provider,
    codex_cli_provider,
    unknown,
};

/// Determine which provider to create from a name string.
pub fn classifyProvider(name: []const u8) ProviderKind {
    const provider_map = std.StaticStringMap(ProviderKind).initComptime(.{
        .{ "anthropic", .anthropic_provider },
        .{ "openai", .openai_provider },
        .{ "openrouter", .openrouter_provider },
        .{ "ollama", .ollama_provider },
        .{ "gemini", .gemini_provider },
        .{ "google", .gemini_provider },
        .{ "google-gemini", .gemini_provider },
        .{ "claude-cli", .claude_cli_provider },
        .{ "codex-cli", .codex_cli_provider },
        // OpenAI-compatible providers
        .{ "venice", .compatible_provider },
        .{ "vercel", .compatible_provider },
        .{ "vercel-ai", .compatible_provider },
        .{ "cloudflare", .compatible_provider },
        .{ "cloudflare-ai", .compatible_provider },
        .{ "moonshot", .compatible_provider },
        .{ "kimi", .compatible_provider },
        .{ "synthetic", .compatible_provider },
        .{ "opencode", .compatible_provider },
        .{ "opencode-zen", .compatible_provider },
        .{ "zai", .compatible_provider },
        .{ "z.ai", .compatible_provider },
        .{ "glm", .compatible_provider },
        .{ "zhipu", .compatible_provider },
        .{ "minimax", .compatible_provider },
        .{ "bedrock", .compatible_provider },
        .{ "aws-bedrock", .compatible_provider },
        .{ "qianfan", .compatible_provider },
        .{ "baidu", .compatible_provider },
        .{ "qwen", .compatible_provider },
        .{ "dashscope", .compatible_provider },
        .{ "qwen-intl", .compatible_provider },
        .{ "dashscope-intl", .compatible_provider },
        .{ "qwen-us", .compatible_provider },
        .{ "dashscope-us", .compatible_provider },
        .{ "groq", .compatible_provider },
        .{ "mistral", .compatible_provider },
        .{ "xai", .compatible_provider },
        .{ "grok", .compatible_provider },
        .{ "deepseek", .compatible_provider },
        .{ "together", .compatible_provider },
        .{ "together-ai", .compatible_provider },
        .{ "fireworks", .compatible_provider },
        .{ "fireworks-ai", .compatible_provider },
        .{ "perplexity", .compatible_provider },
        .{ "cohere", .compatible_provider },
        .{ "copilot", .compatible_provider },
        .{ "github-copilot", .compatible_provider },
        .{ "lmstudio", .compatible_provider },
        .{ "lm-studio", .compatible_provider },
        .{ "nvidia", .compatible_provider },
        .{ "nvidia-nim", .compatible_provider },
        .{ "build.nvidia.com", .compatible_provider },
        .{ "astrai", .compatible_provider },
    });

    if (provider_map.get(name)) |kind| return kind;

    // custom: prefix
    if (std.mem.startsWith(u8, name, "custom:")) return .compatible_provider;

    // anthropic-custom: prefix
    if (std.mem.startsWith(u8, name, "anthropic-custom:")) return .anthropic_provider;

    return .unknown;
}

/// Auto-detect provider kind from an API key prefix.
pub fn detectProviderByApiKey(key: []const u8) ProviderKind {
    if (key.len < 3) return .unknown;
    if (std.mem.startsWith(u8, key, "sk-or-")) return .openrouter_provider;
    if (std.mem.startsWith(u8, key, "sk-ant-")) return .anthropic_provider;
    if (std.mem.startsWith(u8, key, "sk-")) return .openai_provider;
    if (std.mem.startsWith(u8, key, "gsk_")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "xai-")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "pplx-")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "AKIA")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "AIza")) return .gemini_provider;
    return .unknown;
}

/// Get the base URL for an OpenAI-compatible provider by name.
pub fn compatibleProviderUrl(name: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "venice", "https://api.venice.ai" },
        .{ "vercel", "https://api.vercel.ai" },
        .{ "vercel-ai", "https://api.vercel.ai" },
        .{ "cloudflare", "https://gateway.ai.cloudflare.com/v1" },
        .{ "cloudflare-ai", "https://gateway.ai.cloudflare.com/v1" },
        .{ "moonshot", "https://api.moonshot.cn" },
        .{ "kimi", "https://api.moonshot.cn" },
        .{ "synthetic", "https://api.synthetic.com" },
        .{ "opencode", "https://api.opencode.ai" },
        .{ "opencode-zen", "https://api.opencode.ai" },
        .{ "zai", "https://api.z.ai/api/coding/paas/v4" },
        .{ "z.ai", "https://api.z.ai/api/coding/paas/v4" },
        .{ "glm", "https://api.z.ai/api/paas/v4" },
        .{ "zhipu", "https://api.z.ai/api/paas/v4" },
        .{ "minimax", "https://api.minimaxi.com/v1" },
        .{ "bedrock", "https://bedrock-runtime.us-east-1.amazonaws.com" },
        .{ "aws-bedrock", "https://bedrock-runtime.us-east-1.amazonaws.com" },
        .{ "qianfan", "https://aip.baidubce.com" },
        .{ "baidu", "https://aip.baidubce.com" },
        .{ "qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1" },
        .{ "dashscope", "https://dashscope.aliyuncs.com/compatible-mode/v1" },
        .{ "qwen-intl", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" },
        .{ "dashscope-intl", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" },
        .{ "qwen-us", "https://dashscope-us.aliyuncs.com/compatible-mode/v1" },
        .{ "dashscope-us", "https://dashscope-us.aliyuncs.com/compatible-mode/v1" },
        .{ "groq", "https://api.groq.com/openai" },
        .{ "mistral", "https://api.mistral.ai" },
        .{ "xai", "https://api.x.ai" },
        .{ "grok", "https://api.x.ai" },
        .{ "deepseek", "https://api.deepseek.com" },
        .{ "together", "https://api.together.xyz" },
        .{ "together-ai", "https://api.together.xyz" },
        .{ "fireworks", "https://api.fireworks.ai/inference/v1" },
        .{ "fireworks-ai", "https://api.fireworks.ai/inference/v1" },
        .{ "perplexity", "https://api.perplexity.ai" },
        .{ "cohere", "https://api.cohere.com/compatibility" },
        .{ "copilot", "https://api.githubcopilot.com" },
        .{ "github-copilot", "https://api.githubcopilot.com" },
        .{ "lmstudio", "http://localhost:1234/v1" },
        .{ "lm-studio", "http://localhost:1234/v1" },
        .{ "nvidia", "https://integrate.api.nvidia.com/v1" },
        .{ "nvidia-nim", "https://integrate.api.nvidia.com/v1" },
        .{ "build.nvidia.com", "https://integrate.api.nvidia.com/v1" },
        .{ "astrai", "https://as-trai.com/v1" },
    });
    return map.get(name);
}

/// Get the display name for an OpenAI-compatible provider.
pub fn compatibleProviderDisplayName(name: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "venice", "Venice" },
        .{ "vercel", "Vercel AI Gateway" },
        .{ "vercel-ai", "Vercel AI Gateway" },
        .{ "cloudflare", "Cloudflare AI Gateway" },
        .{ "cloudflare-ai", "Cloudflare AI Gateway" },
        .{ "moonshot", "Moonshot" },
        .{ "kimi", "Moonshot" },
        .{ "synthetic", "Synthetic" },
        .{ "opencode", "OpenCode Zen" },
        .{ "opencode-zen", "OpenCode Zen" },
        .{ "zai", "Z.AI" },
        .{ "z.ai", "Z.AI" },
        .{ "glm", "GLM" },
        .{ "zhipu", "GLM" },
        .{ "minimax", "MiniMax" },
        .{ "bedrock", "Amazon Bedrock" },
        .{ "aws-bedrock", "Amazon Bedrock" },
        .{ "qianfan", "Qianfan" },
        .{ "baidu", "Qianfan" },
        .{ "qwen", "Qwen" },
        .{ "dashscope", "Qwen" },
        .{ "qwen-intl", "Qwen" },
        .{ "dashscope-intl", "Qwen" },
        .{ "qwen-us", "Qwen" },
        .{ "dashscope-us", "Qwen" },
        .{ "groq", "Groq" },
        .{ "mistral", "Mistral" },
        .{ "xai", "xAI" },
        .{ "grok", "xAI" },
        .{ "deepseek", "DeepSeek" },
        .{ "together", "Together AI" },
        .{ "together-ai", "Together AI" },
        .{ "fireworks", "Fireworks AI" },
        .{ "fireworks-ai", "Fireworks AI" },
        .{ "perplexity", "Perplexity" },
        .{ "cohere", "Cohere" },
        .{ "copilot", "GitHub Copilot" },
        .{ "github-copilot", "GitHub Copilot" },
        .{ "lmstudio", "LM Studio" },
        .{ "lm-studio", "LM Studio" },
        .{ "nvidia", "NVIDIA NIM" },
        .{ "nvidia-nim", "NVIDIA NIM" },
        .{ "build.nvidia.com", "NVIDIA NIM" },
        .{ "astrai", "Astrai" },
    });
    return map.get(name) orelse "Custom";
}

// ════════════════════════════════════════════════════════════════════════════
// High-level complete function (legacy compatibility)
// ════════════════════════════════════════════════════════════════════════════

/// High-level complete function that routes to the right provider via HTTP.
/// Used by agent.zig for backward compatibility.
pub fn complete(allocator: std.mem.Allocator, cfg: anytype, prompt: []const u8) ![]const u8 {
    const api_key = cfg.api_key orelse return error.NoApiKey;
    const url = providerUrl(cfg.default_provider);
    const model = cfg.default_model orelse "anthropic/claude-sonnet-4-5-20250929";
    const body_str = try buildRequestBody(allocator, model, prompt, cfg.temperature, cfg.max_tokens);
    defer allocator.free(body_str);

    const auth_val = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_val);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer allocator.free(aw.writer.buffer);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body_str,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_val },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.ProviderError;

    const response_body = aw.writer.buffer[0..aw.writer.end];
    return try extractContent(allocator, response_body);
}

/// Like complete() but prepends a system prompt. OpenAI-compatible format.
pub fn completeWithSystem(allocator: std.mem.Allocator, cfg: anytype, system_prompt: []const u8, prompt: []const u8) ![]const u8 {
    const api_key = cfg.api_key orelse return error.NoApiKey;
    const url = providerUrl(cfg.default_provider);
    const model = cfg.default_model orelse "anthropic/claude-sonnet-4-5-20250929";
    const max_tok: u32 = if (cfg.max_tokens) |mt| @intCast(@min(mt, std.math.maxInt(u32))) else 4096;
    const body_str = try buildRequestBodyWithSystem(allocator, model, system_prompt, prompt, cfg.temperature, max_tok);
    defer allocator.free(body_str);

    const auth_val = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_val);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer allocator.free(aw.writer.buffer);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body_str,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_val },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.ProviderError;

    const response_body = aw.writer.buffer[0..aw.writer.end];
    return try extractContent(allocator, response_body);
}

/// Provider URL mapping for the legacy complete() function.
pub fn providerUrl(provider_name: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "anthropic", "https://api.anthropic.com/v1/messages" },
        .{ "openai", "https://api.openai.com/v1/chat/completions" },
        .{ "ollama", "http://localhost:11434/api/chat" },
        .{ "gemini", "https://generativelanguage.googleapis.com/v1beta" },
        .{ "google", "https://generativelanguage.googleapis.com/v1beta" },
    });
    return map.get(provider_name) orelse "https://openrouter.ai/api/v1/chat/completions";
}

/// Build a JSON request body for the legacy complete() function.
pub fn buildRequestBody(allocator: std.mem.Allocator, model: []const u8, prompt: []const u8, temperature: f64, max_tokens: u32) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"model\":");
    try json_util.appendJsonString(&buf, allocator, model);
    try w.writeAll(",\"messages\":[{\"role\":\"user\",\"content\":");
    try json_util.appendJsonString(&buf, allocator, prompt);
    try std.fmt.format(w, "}}],\"temperature\":{d:.1},\"max_tokens\":{d}}}", .{ temperature, max_tokens });
    return try buf.toOwnedSlice(allocator);
}

/// Build a JSON request body with a system prompt (OpenAI-compatible format).
pub fn buildRequestBodyWithSystem(allocator: std.mem.Allocator, model: []const u8, system: []const u8, prompt: []const u8, temperature: f64, max_tokens: u32) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"messages\":[{\"role\":\"system\",\"content\":");
    try json_util.appendJsonString(&buf, allocator, system);
    try w.writeAll("},{\"role\":\"user\",\"content\":");
    try json_util.appendJsonString(&buf, allocator, prompt);
    try std.fmt.format(w, "}}],\"temperature\":{d:.1},\"max_tokens\":{d}}}", .{ temperature, max_tokens });
    return try buf.toOwnedSlice(allocator);
}

/// Re-export shared JSON string utility (used by sub-modules via `root.appendJsonString`).
pub const appendJsonString = json_util.appendJsonString;

/// Re-export shared HTTP POST utility (used by sub-modules via `root.curlPost`).
pub const curlPost = http_util.curlPost;

/// Extract text content from a provider JSON response.
pub fn extractContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;

    // OpenAI/OpenRouter format: choices[0].message.content
    if (root_obj.get("choices")) |choices| {
        if (choices.array.items.len > 0) {
            if (choices.array.items[0].object.get("message")) |msg| {
                if (msg.object.get("content")) |content| {
                    if (content == .string) return try allocator.dupe(u8, content.string);
                }
            }
        }
    }

    // Anthropic format: content[0].text
    if (root_obj.get("content")) |content| {
        if (content.array.items.len > 0) {
            if (content.array.items[0].object.get("text")) |text| {
                if (text == .string) return try allocator.dupe(u8, text.string);
            }
        }
    }

    return error.UnexpectedResponse;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "Role.toSlice returns correct strings" {
    try std.testing.expectEqualStrings("system", Role.system.toSlice());
    try std.testing.expectEqualStrings("user", Role.user.toSlice());
    try std.testing.expectEqualStrings("assistant", Role.assistant.toSlice());
    try std.testing.expectEqualStrings("tool", Role.tool.toSlice());
}

test "Role.fromSlice parses correctly" {
    try std.testing.expect(Role.fromSlice("system").? == .system);
    try std.testing.expect(Role.fromSlice("user").? == .user);
    try std.testing.expect(Role.fromSlice("assistant").? == .assistant);
    try std.testing.expect(Role.fromSlice("tool").? == .tool);
    try std.testing.expect(Role.fromSlice("unknown") == null);
}

test "ChatMessage constructors" {
    const sys = ChatMessage.system("Be helpful");
    try std.testing.expect(sys.role == .system);
    try std.testing.expectEqualStrings("Be helpful", sys.content);

    const usr = ChatMessage.user("Hello");
    try std.testing.expect(usr.role == .user);

    const asst = ChatMessage.assistant("Hi there");
    try std.testing.expect(asst.role == .assistant);

    const tool_msg = ChatMessage.toolMsg("{}", "call_123");
    try std.testing.expect(tool_msg.role == .tool);
    try std.testing.expectEqualStrings("call_123", tool_msg.tool_call_id.?);
}

test "ChatResponse helpers" {
    const empty = ChatResponse{};
    try std.testing.expect(!empty.hasToolCalls());
    try std.testing.expectEqualStrings("", empty.contentOrEmpty());

    const calls = [_]ToolCall{.{ .id = "1", .name = "shell", .arguments = "{}" }};
    const with_tools = ChatResponse{
        .content = "Let me check",
        .tool_calls = &calls,
    };
    try std.testing.expect(with_tools.hasToolCalls());
    try std.testing.expectEqualStrings("Let me check", with_tools.contentOrEmpty());
}

test "providerUrl returns correct URLs" {
    try std.testing.expectEqualStrings(
        "https://api.anthropic.com/v1/messages",
        providerUrl("anthropic"),
    );
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/chat/completions",
        providerUrl("openai"),
    );
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/api/v1/chat/completions",
        providerUrl("openrouter"),
    );
    try std.testing.expectEqualStrings(
        "http://localhost:11434/api/chat",
        providerUrl("ollama"),
    );
}

test "classifyProvider identifies known providers" {
    try std.testing.expect(classifyProvider("anthropic") == .anthropic_provider);
    try std.testing.expect(classifyProvider("openai") == .openai_provider);
    try std.testing.expect(classifyProvider("openrouter") == .openrouter_provider);
    try std.testing.expect(classifyProvider("ollama") == .ollama_provider);
    try std.testing.expect(classifyProvider("gemini") == .gemini_provider);
    try std.testing.expect(classifyProvider("google") == .gemini_provider);
    try std.testing.expect(classifyProvider("groq") == .compatible_provider);
    try std.testing.expect(classifyProvider("mistral") == .compatible_provider);
    try std.testing.expect(classifyProvider("deepseek") == .compatible_provider);
    try std.testing.expect(classifyProvider("venice") == .compatible_provider);
    try std.testing.expect(classifyProvider("custom:https://example.com") == .compatible_provider);
    try std.testing.expect(classifyProvider("nonexistent") == .unknown);
}

test "compatibleProviderUrl returns correct URLs" {
    try std.testing.expectEqualStrings("https://api.venice.ai", compatibleProviderUrl("venice").?);
    try std.testing.expectEqualStrings("https://api.groq.com/openai", compatibleProviderUrl("groq").?);
    try std.testing.expectEqualStrings("https://api.deepseek.com", compatibleProviderUrl("deepseek").?);
    try std.testing.expect(compatibleProviderUrl("nonexistent") == null);
}

test "scrubSecretPatterns redacts sk- tokens" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "request failed: sk-1234567890abcdef");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "sk-1234567890abcdef") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "scrubSecretPatterns handles multiple prefixes" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "keys sk-abcdef xoxb-12345 xoxp-67890");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "sk-abcdef") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "xoxb-12345") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "xoxp-67890") == null);
}

test "scrubSecretPatterns keeps bare prefix" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "only prefix sk- present");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "sk-") != null);
}

test "sanitizeApiError truncates long errors" {
    const allocator = std.testing.allocator;
    const long = try allocator.alloc(u8, 400);
    defer allocator.free(long);
    @memset(long, 'a');
    const result = try sanitizeApiError(allocator, long);
    defer allocator.free(result);
    try std.testing.expect(result.len <= MAX_API_ERROR_CHARS + 3);
    try std.testing.expect(std.mem.endsWith(u8, result, "..."));
}

test "sanitizeApiError no secret no change" {
    const allocator = std.testing.allocator;
    const result = try sanitizeApiError(allocator, "simple upstream timeout");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("simple upstream timeout", result);
}

test "extractContent parses OpenAI format" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"content":"Hello there!"}}]}
    ;
    const result = try extractContent(allocator, body);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello there!", result);
}

test "extractContent parses Anthropic format" {
    const allocator = std.testing.allocator;
    const body =
        \\{"content":[{"type":"text","text":"Hello from Claude"}]}
    ;
    const result = try extractContent(allocator, body);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello from Claude", result);
}

test "ConversationMessage union variants" {
    const chat_msg: ConversationMessage = .{ .chat = ChatMessage.user("hi") };
    try std.testing.expect(chat_msg == .chat);
    try std.testing.expect(chat_msg.chat.role == .user);

    const calls = [_]ToolCall{.{ .id = "1", .name = "shell", .arguments = "{}" }};
    const tc_msg: ConversationMessage = .{ .assistant_tool_calls = .{
        .text = "calling shell",
        .tool_calls = &calls,
    } };
    try std.testing.expect(tc_msg == .assistant_tool_calls);
    try std.testing.expectEqualStrings("calling shell", tc_msg.assistant_tool_calls.text);

    const results = [_]ToolResultMessage{.{ .tool_call_id = "1", .content = "ok" }};
    const tr_msg: ConversationMessage = .{ .tool_results = &results };
    try std.testing.expect(tr_msg == .tool_results);
    try std.testing.expect(tr_msg.tool_results.len == 1);
}

test "provider warmup no-op when vtable warmup is null" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return "";
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: ChatRequest, _: []const u8, _: f64) anyerror!ChatResponse {
            return .{};
        }
        fn supNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };
    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supNativeTools,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
        // warmup, chat_with_tools, supports_streaming all default to null
    };
    const provider = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };
    // Should not crash
    provider.warmup();
}

test "provider supportsStreaming returns false when vtable is null" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return "";
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: ChatRequest, _: []const u8, _: f64) anyerror!ChatResponse {
            return .{};
        }
        fn supNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };
    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supNativeTools,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };
    try std.testing.expect(!provider.supportsStreaming());
}

test "provider chatWithTools falls back to chat when vtable is null" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return "";
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: ChatRequest, _: []const u8, _: f64) anyerror!ChatResponse {
            return .{ .content = "fallback response", .model = "test-model" };
        }
        fn supNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };
    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supNativeTools,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };
    const msgs = [_]ChatMessage{ChatMessage.user("test")};
    const req = ChatRequest{ .messages = &msgs, .model = "test-model" };
    const resp = try provider.chatWithTools(std.testing.allocator, req);
    try std.testing.expectEqualStrings("fallback response", resp.content.?);
    try std.testing.expectEqualStrings("test-model", resp.model);
}

test "nvidia resolves to correct URL" {
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1", compatibleProviderUrl("nvidia").?);
}

test "lm-studio resolves to localhost:1234" {
    try std.testing.expectEqualStrings("http://localhost:1234/v1", compatibleProviderUrl("lm-studio").?);
}

test "astrai resolves to astrai API URL" {
    try std.testing.expectEqualStrings("https://as-trai.com/v1", compatibleProviderUrl("astrai").?);
}

test "anthropic-custom prefix classifies as anthropic provider" {
    try std.testing.expect(classifyProvider("anthropic-custom:https://my-api.example.com") == .anthropic_provider);
}

test "NVIDIA_API_KEY env resolves nvidia credential" {
    const allocator = std.testing.allocator;
    // providerEnvCandidates returns NVIDIA_API_KEY for nvidia
    const candidates = providerEnvCandidates("nvidia");
    try std.testing.expectEqualStrings("NVIDIA_API_KEY", candidates[0]);
    // Also check aliases
    const candidates_nim = providerEnvCandidates("nvidia-nim");
    try std.testing.expectEqualStrings("NVIDIA_API_KEY", candidates_nim[0]);
    const candidates_build = providerEnvCandidates("build.nvidia.com");
    try std.testing.expectEqualStrings("NVIDIA_API_KEY", candidates_build[0]);
    _ = allocator;
}

test "new providers display names" {
    try std.testing.expectEqualStrings("NVIDIA NIM", compatibleProviderDisplayName("nvidia"));
    try std.testing.expectEqualStrings("NVIDIA NIM", compatibleProviderDisplayName("nvidia-nim"));
    try std.testing.expectEqualStrings("NVIDIA NIM", compatibleProviderDisplayName("build.nvidia.com"));
    try std.testing.expectEqualStrings("LM Studio", compatibleProviderDisplayName("lmstudio"));
    try std.testing.expectEqualStrings("LM Studio", compatibleProviderDisplayName("lm-studio"));
    try std.testing.expectEqualStrings("Astrai", compatibleProviderDisplayName("astrai"));
}

test "new providers classify as compatible" {
    try std.testing.expect(classifyProvider("nvidia") == .compatible_provider);
    try std.testing.expect(classifyProvider("nvidia-nim") == .compatible_provider);
    try std.testing.expect(classifyProvider("build.nvidia.com") == .compatible_provider);
    try std.testing.expect(classifyProvider("lmstudio") == .compatible_provider);
    try std.testing.expect(classifyProvider("lm-studio") == .compatible_provider);
    try std.testing.expect(classifyProvider("astrai") == .compatible_provider);
}

test "astrai env candidate is ASTRAI_API_KEY" {
    const candidates = providerEnvCandidates("astrai");
    try std.testing.expectEqualStrings("ASTRAI_API_KEY", candidates[0]);
}

// ── Credential Scrubbing Extended Tests ─────────────────────────

test "scrubSecretPatterns redacts ghp_ GitHub tokens" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "token is ghp_ABCDef123456789012345678901234567890");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "scrubSecretPatterns redacts gho_ GitHub OAuth tokens" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "got gho_abcdef12345");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "gho_abcdef") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "scrubSecretPatterns redacts glpat- GitLab tokens" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "gitlab glpat-ABCDEF123456");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "glpat-ABCDEF") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "scrubSecretPatterns redacts AKIA AWS keys" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "aws AKIAIOSFODNN7EXAMPLE");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "AKIAIOSFODNN7EXAMPLE") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "scrubSecretPatterns redacts api_key=VALUE pattern" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "config: api_key=sk_live_1234567890abcdef");
    defer allocator.free(result);
    // Should keep key name and first 4 chars of value
    try std.testing.expect(std.mem.indexOf(u8, result, "api_key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sk_l") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    // Full value should not be present
    try std.testing.expect(std.mem.indexOf(u8, result, "sk_live_1234567890abcdef") == null);
}

test "scrubSecretPatterns redacts token: VALUE pattern" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "token: mySecretToken123");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "token: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mySecretToken123") == null);
}

test "scrubSecretPatterns redacts password=VALUE pattern" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "PASSWORD=hunter2 rest");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "hunter2") == null);
}

test "scrubSecretPatterns redacts Bearer TOKEN pattern" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.secret");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bearer ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.secret") == null);
}

test "scrubSecretPatterns redacts secret= with quoted value" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "secret=\"my_very_secret_value\" next");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "my_very_secret_value") == null);
}

test "scrubSecretPatterns no false positives on normal text" {
    const allocator = std.testing.allocator;
    const result = try scrubSecretPatterns(allocator, "the password policy requires 8 chars. See token docs.");
    defer allocator.free(result);
    // "password" and "token" without separator should not trigger redaction
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") == null);
}

test "scrubToolOutput truncates long output" {
    const allocator = std.testing.allocator;
    const long = try allocator.alloc(u8, 15_000);
    defer allocator.free(long);
    @memset(long, 'x');
    const result = try scrubToolOutput(allocator, long);
    defer allocator.free(result);
    try std.testing.expect(result.len < 15_000);
    try std.testing.expect(std.mem.endsWith(u8, result, "[output truncated]"));
}

test "scrubToolOutput scrubs secrets and truncates" {
    const allocator = std.testing.allocator;
    const result = try scrubToolOutput(allocator, "cat .env output: api_key=sk_live_abcdef123456");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sk_live_abcdef123456") == null);
}

test "scrubToolOutput passes through clean short output" {
    const allocator = std.testing.allocator;
    const result = try scrubToolOutput(allocator, "ls output: file1.txt file2.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls output: file1.txt file2.txt", result);
}

test "scrubSecretPatterns handles multiple patterns in one string" {
    const allocator = std.testing.allocator;
    const input = "keys: api_key=abc123 token=xyz789 ghp_TokenHere sk-mykey123";
    const result = try scrubSecretPatterns(allocator, input);
    defer allocator.free(result);
    // All secrets should be redacted
    try std.testing.expect(std.mem.indexOf(u8, result, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "xyz789") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ghp_TokenHere") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sk-mykey123") == null);
}

test "eqlLowercase matches case-insensitively" {
    try std.testing.expect(eqlLowercase("API_KEY", "api_key"));
    try std.testing.expect(eqlLowercase("api_key", "api_key"));
    try std.testing.expect(eqlLowercase("Api_Key", "api_key"));
    try std.testing.expect(!eqlLowercase("api_keys", "api_key")); // different length — won't match
}

test "ChatResponse reasoning_content defaults to null" {
    const resp = ChatResponse{};
    try std.testing.expect(resp.reasoning_content == null);
}

test "ChatResponse reasoning_content can be set" {
    const resp = ChatResponse{ .reasoning_content = "Let me think..." };
    try std.testing.expectEqualStrings("Let me think...", resp.reasoning_content.?);
}

test "detectProviderByApiKey openrouter" {
    try std.testing.expect(detectProviderByApiKey("sk-or-v1-abc123") == .openrouter_provider);
}

test "detectProviderByApiKey anthropic" {
    try std.testing.expect(detectProviderByApiKey("sk-ant-api03-abc123") == .anthropic_provider);
}

test "detectProviderByApiKey openai" {
    try std.testing.expect(detectProviderByApiKey("sk-proj-abc123") == .openai_provider);
}

test "detectProviderByApiKey groq" {
    try std.testing.expect(detectProviderByApiKey("gsk_abc123def456") == .compatible_provider);
}

test "detectProviderByApiKey xai" {
    try std.testing.expect(detectProviderByApiKey("xai-abc123") == .compatible_provider);
}

test "detectProviderByApiKey perplexity" {
    try std.testing.expect(detectProviderByApiKey("pplx-abc123") == .compatible_provider);
}

test "detectProviderByApiKey aws" {
    try std.testing.expect(detectProviderByApiKey("AKIAIOSFODNN7EXAMPLE") == .compatible_provider);
}

test "detectProviderByApiKey gemini" {
    try std.testing.expect(detectProviderByApiKey("AIzaSyAbc123") == .gemini_provider);
}

test "detectProviderByApiKey unknown" {
    try std.testing.expect(detectProviderByApiKey("random-key") == .unknown);
}

test "detectProviderByApiKey short key" {
    try std.testing.expect(detectProviderByApiKey("ab") == .unknown);
}

test "StreamChatResult defaults" {
    const result = StreamChatResult{};
    try std.testing.expect(result.content == null);
    try std.testing.expect(result.usage.prompt_tokens == 0);
    try std.testing.expect(result.usage.completion_tokens == 0);
    try std.testing.expectEqualStrings("", result.model);
}

test "Provider.streamChat fallback emits single chunk and final" {
    const TestCtx = struct {
        chunks_count: usize = 0,
        got_content: bool = false,
        got_final: bool = false,

        fn onChunk(ctx_ptr: *anyopaque, chunk: StreamChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.chunks_count += 1;
            if (!chunk.is_final and chunk.delta.len > 0) self.got_content = true;
            if (chunk.is_final) self.got_final = true;
        }
    };

    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return "";
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: ChatRequest, _: []const u8, _: f64) anyerror!ChatResponse {
            return .{ .content = "hello from fallback", .model = "test" };
        }
        fn supNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var dummy: u8 = 0;
    const vtable_val = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supNativeTools,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const prov = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable_val };

    var ctx = TestCtx{};
    const msgs = [_]ChatMessage{ChatMessage.user("test")};
    const req = ChatRequest{ .messages = &msgs, .model = "test" };
    const result = try prov.streamChat(std.testing.allocator, req, "test", 0.7, TestCtx.onChunk, @ptrCast(&ctx));

    try std.testing.expect(ctx.got_content);
    try std.testing.expect(ctx.got_final);
    try std.testing.expect(ctx.chunks_count == 2);
    try std.testing.expectEqualStrings("hello from fallback", result.content.?);
}

test "buildRequestBody escapes double quotes in prompt" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4o", "say \"hello\"", 0.7, 100);
    defer allocator.free(body);
    // Raw quote would break JSON; escaped form must be present
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hello\\\"") != null);
    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "buildRequestBody escapes newlines in prompt" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4o", "line1\nline2", 0.7, 100);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "buildRequestBody escapes backslash in prompt" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4o", "path\\to\\file", 0.7, 100);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\\") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "buildRequestBodyWithSystem escapes special chars in both fields" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBodyWithSystem(allocator, "gpt-4o", "sys \"role\"", "user\nprompt", 0.7, 100);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"role\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "appendJsonString encodes control chars as \\uXXXX" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    // BEL character (0x07) should be encoded as \u0007
    try json_util.appendJsonString(&buf, allocator, "\x07");
    try std.testing.expectEqualStrings("\"\\u0007\"", buf.items);
}

// ── Multimodal Content Part Tests ────────────────────────────────

test "makeTextPart creates text content part" {
    const part = makeTextPart("Hello world");
    try std.testing.expect(part == .text);
    try std.testing.expectEqualStrings("Hello world", part.text);
}

test "makeImageUrlPart creates image_url content part with auto detail" {
    const part = makeImageUrlPart("https://example.com/image.png");
    try std.testing.expect(part == .image_url);
    try std.testing.expectEqualStrings("https://example.com/image.png", part.image_url.url);
    try std.testing.expect(part.image_url.detail == .auto);
}

test "makeBase64ImagePart creates image_base64 content part" {
    const part = makeBase64ImagePart("iVBORw0KGgo=", "image/png");
    try std.testing.expect(part == .image_base64);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", part.image_base64.data);
    try std.testing.expectEqualStrings("image/png", part.image_base64.media_type);
}

test "ImageDetail.toSlice returns correct strings" {
    try std.testing.expectEqualStrings("auto", ImageDetail.auto.toSlice());
    try std.testing.expectEqualStrings("low", ImageDetail.low.toSlice());
    try std.testing.expectEqualStrings("high", ImageDetail.high.toSlice());
}

test "ChatMessage content_parts defaults to null" {
    const msg = ChatMessage.user("hello");
    try std.testing.expect(msg.content_parts == null);
}

test "ChatMessage with content_parts set" {
    const parts = [_]ContentPart{
        makeTextPart("Describe this image"),
        makeImageUrlPart("https://example.com/cat.jpg"),
    };
    const msg = ChatMessage{
        .role = .user,
        .content = "",
        .content_parts = &parts,
    };
    try std.testing.expect(msg.content_parts != null);
    try std.testing.expect(msg.content_parts.?.len == 2);
    try std.testing.expect(msg.content_parts.?[0] == .text);
    try std.testing.expect(msg.content_parts.?[1] == .image_url);
}

test {
    // Run tests from all sub-modules
    std.testing.refAllDecls(@This());
}
