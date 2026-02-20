#+feature dynamic-literals

package main

import "core:testing"

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:strconv"

PROVIDER_ERROR_NONE :: 0
PROVIDER_ERROR_NETWORK :: 1
PROVIDER_ERROR_PARSE :: 2
PROVIDER_ERROR_API :: 3

Provider_Error :: enum {
    None,
    Network_Error,
    Invalid_Response,
    API_Error,
    Rate_Limited,
}

// Provider interface using vtable
Provider :: struct {
    ptr: rawptr,
    vtable: ^Provider_VTable,
}

Provider_VTable :: struct {
    chat: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError),
    name: proc(ptr: rawptr) -> string,
    deinit: proc(ptr: rawptr),
}

// OpenAIProvider
OpenAIProvider :: struct {
    api_key: string,
    model: string,
    endpoint: string,
}

init_openai_provider :: proc(api_key: string, model: string) -> Provider {
    prov := new(OpenAIProvider)
    prov.api_key = api_key
    prov.model = model
    prov.endpoint = "https://api.openai.com/v1/chat/completions"
    return Provider{ptr = prov, vtable = &openai_vtable}
}

openai_vtable := Provider_VTable{
    chat = openai_chat,
    name = openai_name,
    deinit = openai_deinit,
}

openai_name :: proc(ptr: rawptr) -> string {
    prov := (^OpenAIProvider)(ptr)
    return fmt.tprintf("openai:%s", prov.model)
}

openai_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

openai_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    prov := (^OpenAIProvider)(ptr)
    
    // Build request body
    request_body := build_openai_request(messages, tools, prov.model)
    defer delete(request_body)
    
    // Make HTTP request
    response_body, err := http_post(prov.endpoint, request_body, prov.api_key)
    if err != .None {
        return Message{}, {}, .ProviderError
    }
    defer delete(response_body)
    
    // Parse response
    return parse_openai_response(response_body)
}

build_openai_request :: proc(messages: []Message, tools: []Tool, model: string) -> string {
    // Simple JSON building - in production use proper JSON builder
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    
    strings.write_string(&sb, `{"model":"`)
    strings.write_string(&sb, model)
    strings.write_string(&sb, `","messages":[`)
    
    for msg in messages {
        strings.write_string(&sb, `{"role":"`)
        strings.write_string(&sb, msg.role)
        strings.write_string(&sb, `","content":`)
        
        // Escape content
        escaped := escape_json_string(msg.content)
        strings.write_string(&sb, `"`)
        strings.write_string(&sb, escaped)
        strings.write_string(&sb, `"}`)
        delete(escaped)
    }
    
    strings.write_string(&sb, `],"stream":false}`)
    
    return strings.to_string(sb)
}

escape_json_string :: proc(s: string) -> string {
    result := strings.builder_make()
    
    for c in s {
        switch c {
        case '"':
            strings.write_string(&result, "\\\"")
        case '\\':
            strings.write_string(&result, "\\\\")
        case '\n':
            strings.write_string(&result, "\\n")
        case '\r':
            strings.write_string(&result, "\\r")
        case '\t':
            strings.write_string(&result, "\\t")
        case:
            strings.write_rune(&result, c)
        }
    }
    return strings.to_string(result)
}

http_post :: proc(url: string, body: string, api_key: string) -> (string, Provider_Error) {
    headers := []string{
        fmt.tprintf("Authorization: Bearer %s", api_key),
        "Content-Type: application/json",
    }
    resp, err := http_post_request(url, body, headers)
    if err != .None {
        return "", .Network_Error
    }
    if resp.status_code < 200 || resp.status_code >= 300 {
        return "", .API_Error
    }
    return resp.body, .None
}

fast_atoi :: proc(s: string) -> int {
    result := 0
    for i := 0; i < len(s); i += 1 {
        c := int(s[i])
        if c < 48 || c > 57 {
            break
        }
        result = result * 10 + (c - 48)
    }
    return result
}

parse_openai_response :: proc(body: string) -> (Message, []ToolCall, AgentError) {
    // Simple JSON parsing - look for content
    // In production, use proper JSON parser
    
    msg := Message{role = "assistant"}
    tool_calls := make([]ToolCall, 0)
    
    // Find "content"
    if content_idx := strings.index(body, `"content"`); content_idx >= 0 {
        // Find the value after "content":
        search_start := content_idx + 8
        if search_start < len(body) {
            // Skip past : and whitespace
            for search_start < len(body) && (body[search_start] == ':' || body[search_start] == ' ' || body[search_start] == '\t') {
                search_start += 1
            }
            if search_start < len(body) && body[search_start] == '"' {
                search_start += 1
                end := search_start
                for end < len(body) && body[end] != '"' {
                    if body[end] == '\\' && end + 1 < len(body) {
                        end += 2
                    } else {
                        end += 1
                    }
                }
                if end > search_start {
                    msg.content = body[search_start:end]
                }
            }
        }
    }
    
    // Look for tool calls
    if tc_idx := strings.index(body, `"tool_calls"`); tc_idx >= 0 {
        // Parse tool calls
        // Simplified - in production use proper parser
        tool_calls = make([]ToolCall, 1)
        tool_calls[0] = ToolCall{
            id = "call_1",
            name = "shell",
            arguments = make(map[string]json.Value),
        }
        tool_calls[0].arguments["command"] = json.String("echo from openai")
    }
    
    return msg, tool_calls, .None
}

// xAI Provider (Grok)
xAIProvider :: struct {
    api_key: string,
    model: string,
    endpoint: string,
}

init_xai_provider :: proc(api_key: string, model: string) -> Provider {
    prov := new(xAIProvider)
    prov.api_key = api_key
    prov.model = model
    prov.endpoint = "https://api.x.ai/v1/chat/completions"
    return Provider{ptr = prov, vtable = &xai_vtable}
}

xai_vtable := Provider_VTable{
    chat = xai_chat,
    name = xai_name,
    deinit = xai_deinit,
}

xai_name :: proc(ptr: rawptr) -> string {
    prov := (^xAIProvider)(ptr)
    return fmt.tprintf("xai:%s", prov.model)
}

xai_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

xai_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    prov := (^xAIProvider)(ptr)
    
    request_body := build_openai_request(messages, tools, prov.model) // Same format as OpenAI
    defer delete(request_body)
    
    response_body, err := http_post(prov.endpoint, request_body, prov.api_key)
    if err != .None {
        return Message{}, {}, .ProviderError
    }
    defer delete(response_body)
    
    return parse_openai_response(response_body)
}

// Anthropic Provider
AnthropicProvider :: struct {
    api_key: string,
    model: string,
    endpoint: string,
}

init_anthropic_provider :: proc(api_key: string, model: string) -> Provider {
    prov := new(AnthropicProvider)
    prov.api_key = api_key
    prov.model = model
    prov.endpoint = "https://api.anthropic.com/v1/messages"
    return Provider{ptr = prov, vtable = &anthropic_vtable}
}

anthropic_vtable := Provider_VTable{
    chat = anthropic_chat,
    name = anthropic_name,
    deinit = anthropic_deinit,
}

anthropic_name :: proc(ptr: rawptr) -> string {
    prov := (^AnthropicProvider)(ptr)
    return fmt.tprintf("anthropic:%s", prov.model)
}

anthropic_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

anthropic_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    prov := (^AnthropicProvider)(ptr)
    
    // Build Anthropic request
    request_body := build_anthropic_request(messages, tools, prov.model)
    defer delete(request_body)
    
    response_body, err := anthropic_http_post(prov.endpoint, request_body, prov.api_key, prov.model)
    if err != .None {
        return Message{}, {}, .ProviderError
    }
    defer delete(response_body)
    
    return parse_anthropic_response(response_body)
}

build_anthropic_request :: proc(messages: []Message, tools: []Tool, model: string) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    
    strings.write_string(&sb, `{"model":"`)
    strings.write_string(&sb, model)
    strings.write_string(&sb, `","messages":[`)
    
    first := true
    for msg in messages {
        // Skip system messages - they go in system prompt
        if msg.role == "system" {
            continue
        }
        if !first {
            strings.write_string(&sb, ",")
        }
        first = false
        
        strings.write_string(&sb, `{"role":"`)
        strings.write_string(&sb, msg.role)
        strings.write_string(&sb, `","content":`)
        
        escaped := escape_json_string(msg.content)
        strings.write_string(&sb, `"`)
        strings.write_string(&sb, escaped)
        strings.write_string(&sb, `"}`)
        delete(escaped)
    }
    
    strings.write_string(&sb, `],"max_tokens":1024}`)
    
    return strings.to_string(sb)
}

anthropic_http_post :: proc(url: string, body: string, api_key: string, model: string) -> (string, Provider_Error) {
    // Stub for now - full implementation needs proper TLS
    return `{"content":"API integration requires TLS support"}`, .None
}

parse_anthropic_response :: proc(body: string) -> (Message, []ToolCall, AgentError) {
    msg := Message{role = "assistant"}
    tool_calls := make([]ToolCall, 0)
    
    // Find content
    if content_idx := strings.index(body, `"content"`); content_idx >= 0 {
        search_start := content_idx + 8
        if search_start < len(body) {
            for search_start < len(body) && (body[search_start] == ':' || body[search_start] == ' ' || body[search_start] == '\t') {
                search_start += 1
            }
            if search_start < len(body) && body[search_start] == '"' {
                search_start += 1
                end := search_start
                for end < len(body) && body[end] != '"' {
                    if body[end] == '\\' && end + 1 < len(body) {
                        end += 2
                    } else {
                        end += 1
                    }
                }
                if end > search_start {
                    msg.content = body[search_start:end]
                }
            }
        }
    }
    
    // Check for tool use
    if strings.contains(body, `"type":"tool_use"`) || strings.contains(body, `"type":"tool_use"`) {
        tool_calls = make([]ToolCall, 1)
        tool_calls[0] = ToolCall{
            id = "call_1",
            name = "shell",
            arguments = make(map[string]json.Value),
        }
        tool_calls[0].arguments["command"] = json.String("echo from anthropic")
    }
    
    return msg, tool_calls, .None
}

// Ollama Provider
OllamaProvider :: struct {
    endpoint: string,
    model: string,
}

init_ollama_provider :: proc(endpoint: string, model: string) -> Provider {
    prov := new(OllamaProvider)
    prov.endpoint = endpoint
    prov.model = model
    return Provider{ptr = prov, vtable = &ollama_vtable}
}

ollama_vtable := Provider_VTable{
    chat = ollama_chat,
    name = ollama_name,
    deinit = ollama_deinit,
}

ollama_name :: proc(ptr: rawptr) -> string {
    prov := (^OllamaProvider)(ptr)
    return fmt.tprintf("ollama:%s", prov.model)
}

ollama_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

ollama_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    prov := (^OllamaProvider)(ptr)
    
    request_body := build_ollama_request(messages, prov.model)
    defer delete(request_body)
    
    url := fmt.tprintf("%s/api/chat", prov.endpoint)
    response_body, err := http_post(url, request_body, "")
    if err != .None {
        return Message{}, {}, .ProviderError
    }
    defer delete(response_body)
    
    return parse_ollama_response(response_body)
}

build_ollama_request :: proc(messages: []Message, model: string) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    
    strings.write_string(&sb, `{"model":"`)
    strings.write_string(&sb, model)
    strings.write_string(&sb, `","messages":[`)
    
    first := true
    for msg in messages {
        if !first {
            strings.write_string(&sb, ",")
        }
        first = false
        
        strings.write_string(&sb, `{"role":"`)
        strings.write_string(&sb, msg.role)
        strings.write_string(&sb, `","content":`)
        
        escaped := escape_json_string(msg.content)
        strings.write_string(&sb, `"`)
        strings.write_string(&sb, escaped)
        strings.write_string(&sb, `"}`)
        delete(escaped)
    }
    
    strings.write_string(&sb, `],"stream":false}`)
    return strings.to_string(sb)
}

parse_ollama_response :: proc(body: string) -> (Message, []ToolCall, AgentError) {
    msg := Message{role = "assistant"}
    tool_calls := make([]ToolCall, 0)
    
    if content_idx := strings.index(body, `"content"`); content_idx >= 0 {
        search_start := content_idx + 8
        for search_start < len(body) && (body[search_start] == ':' || body[search_start] == ' ' || body[search_start] == '\t') {
            search_start += 1
        }
        if search_start < len(body) && body[search_start] == '"' {
            search_start += 1
            end := search_start
            for end < len(body) && body[end] != '"' {
                end += 1
            }
            if end > search_start {
                msg.content = body[search_start:end]
            }
        }
    }
    
    return msg, tool_calls, .None
}

// MockProvider for testing
MockProvider :: struct {
    name: string,
    response: string,
}

// init_mock_provider creates a mock provider
init_mock_provider :: proc(name: string, response: string) -> Provider {
    mock := new(MockProvider)
    mock.name = name
    mock.response = response
    return Provider{ptr = mock, vtable = &mock_provider_vtable}
}

// mock_provider_vtable
mock_provider_vtable := Provider_VTable{
    chat = mock_chat,
    name = mock_name,
    deinit = mock_deinit,
}

// mock_chat returns a mock response with tool call
mock_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    mock := (^MockProvider)(ptr)
    message := Message{role = "assistant", content = mock.response}
    
    // Check if there are tool messages, if yes, no tool calls
    has_tool := false
    for msg in messages {
        if msg.role == "tool" {
            has_tool = true
            break
        }
    }
    
    tool_calls := make([]ToolCall, 0)
    if !has_tool {
        tool_calls = make([]ToolCall, 1)
        tool_calls[0] = ToolCall{
            id = "call1",
            name = "shell",
            arguments = make(map[string]json.Value),
        }
        tool_calls[0].arguments["command"] = json.String("echo hello")
    }
    
    return message, tool_calls, .None
}

// mock_name returns the name
mock_name :: proc(ptr: rawptr) -> string {
    mock := (^MockProvider)(ptr)
    return mock.name
}

// mock_deinit deinitializes
mock_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

// ============================================================================
// OpenAI-Compatible Provider (handles 30+ providers: Groq, DeepSeek, LM Studio, etc.)
// ============================================================================

CompatibleProvider :: struct {
    api_key:  string,
    model:    string,
    endpoint: string,
}

// Known compatible provider endpoints
COMPATIBLE_ENDPOINTS := map[string]string{
    "groq" = "https://api.groq.com/openai",
    "deepseek" = "https://api.deepseek.com",
    "opencode" = "https://api.opencode.ai",
    "opencode-zen" = "https://api.opencode.ai",
    "zen" = "https://api.opencode.ai",
    "vercel" = "https://api.vercel.ai",
    "vercel-ai" = "https://api.vercel.ai",
    "cloudflare" = "https://gateway.ai.cloudflare.com/v1/account/gateway",
    "cloudflare-ai" = "https://gateway.ai.cloudflare.com/v1/account/gateway",
    "moonshot" = "https://api.moonshot.cn/v1",
    "kimi" = "https://api.moonshot.cn/v1",
    "synthetic" = "https://api.synthetic.com/v1",
    "zai" = "https://api.z.ai/v1",
    "z.ai" = "https://api.z.ai/v1",
    "glm" = "https://open.bigmodel.cn/api/paas/v4",
    "zhipu" = "https://open.bigmodel.cn/api/paas/v4",
    "minimax" = "https://api.minimax.chat/v1",
    "bedrock" = "https://bedrock-runtime.us-east-1.amazonaws.com",
    "aws-bedrock" = "https://bedrock-runtime.us-east-1.amazonaws.com",
    "qianfan" = "https://qianfan.baidubce.com/v2",
    "baidu" = "https://qianfan.baidubce.com/v2",
    "qwen" = "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "dashscope" = "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "qwen-intl" = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    "dashscope-intl" = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    "qwen-us" = "https://dashscope-us.aliyuncs.com/compatible-mode/v1",
    "dashscope-us" = "https://dashscope-us.aliyuncs.com/compatible-mode/v1",
    "mistral" = "https://api.mistral.ai/v1",
    "together" = "https://api.together.ai/v1",
    "together-ai" = "https://api.together.ai/v1",
    "fireworks" = "https://api.fireworks.ai/v1",
    "fireworks-ai" = "https://api.fireworks.ai/v1",
    "perplexity" = "https://api.perplexity.ai",
    "cohere" = "https://api.cohere.ai/v1",
    "copilot" = "https://api.github.com/v1",
    "github-copilot" = "https://api.github.com/v1",
    "lmstudio" = "http://localhost:1234/v1",
    "lm-studio" = "http://localhost:1234/v1",
    "nvidia" = "https://integrate.api.nvidia.com/v1",
    "nvidia-nim" = "https://integrate.api.nvidia.com/v1",
    "build.nvidia.com" = "https://integrate.api.nvidia.com/v1",
    "astrai" = "https://as-trai.com/v1",
    "ollama" = "http://localhost:11434/v1",
    "venice" = "https://api.venice.ai",
    "x.ai" = "https://api.x.ai/v1",
}

get_compatible_endpoint :: proc(provider_name: string) -> string {
    if ep, ok := COMPATIBLE_ENDPOINTS[provider_name]; ok {
        return ep
    }
    // Check for custom: prefix
    if strings.has_prefix(provider_name, "custom:") {
        return strings.trim_left(provider_name, "custom:")
    }
    return ""
}

classify_provider_by_key :: proc(api_key: string) -> Provider_Type {
    if len(api_key) == 0 {
        return .Unknown
    }
    // gsk_ = Groq
    if strings.has_prefix(api_key, "gsk_") {
        return .Compatible
    }
    // xai- = xAI
    if strings.has_prefix(api_key, "xai-") {
        return .Compatible
    }
    // pplx- = Perplexity
    if strings.has_prefix(api_key, "pplx-") {
        return .Compatible
    }
    // AKIA = AWS (Bedrock)
    if strings.has_prefix(api_key, "AKIA") {
        return .Compatible
    }
    // sk-ant- = Anthropic (but we have native)
    // sk- = OpenAI or compatible
    if strings.has_prefix(api_key, "sk-") {
        return .OpenAI // Default to OpenAI, can override
    }
    return .Unknown
}

Provider_Type :: enum {
    Unknown,
    OpenAI,
    Anthropic,
    xAI,
    Ollama,
    Compatible,
    Mock,
}

get_provider_type :: proc(name: string, api_key: string) -> Provider_Type {
    lower := strings.to_lower(name)
    
    // Check by name first
    switch lower {
    case "openai":
        return .OpenAI
    case "anthropic", "claude":
        return .Anthropic
    case "xai", "grok":
        return .xAI
    case "ollama":
        return .Ollama
    case "mock":
        return .Mock
    case "compatible":
        return .Compatible
    }
    
    // Check if it's a known compatible provider
    if get_compatible_endpoint(lower) != "" {
        return .Compatible
    }
    
    // Fall back to classifying by API key
    return classify_provider_by_key(api_key)
}

// init_compatible_provider creates an OpenAI-compatible provider
init_compatible_provider :: proc(api_key: string, model: string, provider_name: string) -> Provider {
    prov := new(CompatibleProvider)
    prov.api_key = api_key
    prov.model = model
    
    // Use provided name or default to "compatible"
    name := provider_name
    if name == "" {
        name = "compatible"
    }
    
    endpoint := get_compatible_endpoint(strings.to_lower(name))
    if endpoint == "" {
        endpoint = "https://api.openai.com/v1" // Default fallback
    }
    prov.endpoint = endpoint
    
    return Provider{ptr = prov, vtable = &compatible_vtable}
}

compatible_vtable := Provider_VTable{
    chat = compatible_chat,
    name = compatible_name,
    deinit = compatible_deinit,
}

compatible_name :: proc(ptr: rawptr) -> string {
    prov := (^CompatibleProvider)(ptr)
    return fmt.tprintf("compatible:%s", prov.model)
}

compatible_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

compatible_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    prov := (^CompatibleProvider)(ptr)
    
    request_body := build_openai_request(messages, tools, prov.model)
    defer delete(request_body)
    
    response_body, err := http_post(prov.endpoint, request_body, prov.api_key)
    if err != .None {
        return Message{}, {}, .ProviderError
    }
    
    return parse_openai_response(response_body)
}

// ============================================================================
// Tests
// ============================================================================

@test
test_compatible_endpoint_detection :: proc(t: ^testing.T) {
    testing.expect(t, get_compatible_endpoint("groq") == "https://api.groq.com/openai", "Groq endpoint")
    testing.expect(t, get_compatible_endpoint("deepseek") == "https://api.deepseek.com", "DeepSeek endpoint")
    testing.expect(t, get_compatible_endpoint("ollama") == "http://localhost:11434/v1", "Ollama endpoint")
    testing.expect(t, get_compatible_endpoint("lmstudio") == "http://localhost:1234/v1", "LM Studio endpoint")
    testing.expect(t, get_compatible_endpoint("zen") == "https://api.opencode.ai", "Zen endpoint")
    testing.expect(t, get_compatible_endpoint("unknown") == "", "Unknown returns empty")
}

@test
test_provider_type_detection :: proc(t: ^testing.T) {
    testing.expect(t, get_provider_type("openai", "sk-test") == .OpenAI, "OpenAI by name")
    testing.expect(t, get_provider_type("anthropic", "sk-ant-test") == .Anthropic, "Anthropic by name")
    testing.expect(t, get_provider_type("ollama", "") == .Ollama, "Ollama by name")
    testing.expect(t, get_provider_type("groq", "gsk_test") == .Compatible, "Groq by key prefix")
    testing.expect(t, get_provider_type("deepseek", "sk-test") == .Compatible, "DeepSeek by endpoint")
}

@test
test_classify_provider_by_key :: proc(t: ^testing.T) {
    testing.expect(t, classify_provider_by_key("gsk_abc") == .Compatible, "gsk_ prefix = Compatible")
    testing.expect(t, classify_provider_by_key("xai-abc") == .Compatible, "xai- prefix = Compatible")
    testing.expect(t, classify_provider_by_key("pplx-abc") == .Compatible, "pplx- prefix = Compatible")
    testing.expect(t, classify_provider_by_key("AKIAIOSFODNN7EXAMPLE") == .Compatible, "AWS key = Compatible")
    testing.expect(t, classify_provider_by_key("sk-test") == .OpenAI, "sk- prefix = OpenAI")
}