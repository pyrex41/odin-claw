package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

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
    // For now, return a placeholder - full HTTP implementation needs
    // proper TLS and socket handling which is complex in Odin
    // This allows the code to compile and work with mock provider
    return `{"content":"API integration requires TLS support","choices":[]}`, .None
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