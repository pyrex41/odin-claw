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

    strings.write_string(&sb, `]`)

    // Add tool definitions if tools are available
    if len(tools) > 0 {
        strings.write_string(&sb, `,"tools":[`)
        first_tool := true
        for tool in tools {
            if tool.vtable.schema == nil {
                continue
            }
            if !first_tool {
                strings.write_string(&sb, ",")
            }
            first_tool = false

            name := tool.vtable.name(tool.ptr)
            desc := tool.vtable.description(tool.ptr)
            schema := tool.vtable.schema(tool.ptr)
            escaped_desc := escape_json_string(desc)
            defer delete(escaped_desc)

            strings.write_string(&sb, `{"type":"function","function":{"name":"`)
            strings.write_string(&sb, name)
            strings.write_string(&sb, `","description":"`)
            strings.write_string(&sb, escaped_desc)
            strings.write_string(&sb, `","parameters":`)
            strings.write_string(&sb, schema)
            strings.write_string(&sb, `}}`)
        }
        strings.write_string(&sb, `]`)
    }

    strings.write_string(&sb, `,"stream":false}`)

    return strings.clone(strings.to_string(sb))
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
    defer delete(resp.body)
    if resp.status_code < 200 || resp.status_code >= 300 {
        return "", .API_Error
    }
    return strings.clone(resp.body), .None
}

// parse_json_arguments parses a JSON object string (or escaped JSON string) into a map of string values
// Handles both {"key":"value"} objects and escaped JSON strings like "{\"key\":\"value\"}"
parse_json_arguments :: proc(raw: string) -> map[string]json.Value {
    args := make(map[string]json.Value)
    if len(raw) == 0 {
        return args
    }

    // Determine if this is a raw JSON object or an escaped JSON string
    src := raw
    unescaped: string
    needs_free := false

    // If it starts with { it's already a JSON object
    // If it doesn't, try to unescape it (OpenAI sends arguments as an escaped JSON string)
    if len(src) > 0 && src[0] != '{' {
        return args
    }

    // Parse the JSON object: extract key-value pairs where values are strings
    pos := 1 // skip opening {
    for pos < len(src) && src[pos] != '}' {
        // Skip whitespace and commas
        for pos < len(src) && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r' || src[pos] == ',') {
            pos += 1
        }
        if pos >= len(src) || src[pos] == '}' { break }

        // Expect a key string
        if src[pos] != '"' { break }
        pos += 1
        key_start := pos
        for pos < len(src) && src[pos] != '"' {
            if src[pos] == '\\' { pos += 2 } else { pos += 1 }
        }
        key := src[key_start:pos]
        if pos < len(src) { pos += 1 } // skip closing quote

        // Skip : and whitespace
        for pos < len(src) && (src[pos] == ':' || src[pos] == ' ' || src[pos] == '\t') {
            pos += 1
        }
        if pos >= len(src) { break }

        // Parse the value
        if src[pos] == '"' {
            // String value
            pos += 1
            val_start := pos
            for pos < len(src) {
                if src[pos] == '\\' { pos += 2 } else if src[pos] == '"' { break } else { pos += 1 }
            }
            val := src[val_start:pos]
            if pos < len(src) { pos += 1 } // skip closing quote
            args[strings.clone(key)] = json.String(strings.clone(val))
        } else if src[pos] == '{' || src[pos] == '[' {
            // Nested object/array — skip it and store as string
            end := pos
            if src[pos] == '{' {
                end = find_matching_brace(src, pos)
            } else {
                end = find_matching_bracket(src, pos)
            }
            val := src[pos:end + 1]
            pos = end + 1
            args[strings.clone(key)] = json.String(strings.clone(val))
        } else if pos + 4 <= len(src) && src[pos:pos+4] == "true" {
            args[strings.clone(key)] = json.String("true")
            pos += 4
        } else if pos + 5 <= len(src) && src[pos:pos+5] == "false" {
            args[strings.clone(key)] = json.String("false")
            pos += 5
        } else if pos + 4 <= len(src) && src[pos:pos+4] == "null" {
            pos += 4
        } else {
            // Number — read until delimiter
            val_start := pos
            for pos < len(src) && src[pos] != ',' && src[pos] != '}' && src[pos] != ' ' {
                pos += 1
            }
            val := src[val_start:pos]
            args[strings.clone(key)] = json.String(strings.clone(val))
        }
    }

    if needs_free {
        delete(unescaped)
    }
    return args
}

// find_matching_brace finds the index of the closing } that matches the { at pos
find_matching_brace :: proc(s: string, start: int) -> int {
    depth := 0
    pos := start
    for pos < len(s) {
        if s[pos] == '"' {
            pos += 1
            for pos < len(s) {
                if s[pos] == '\\' { pos += 2 } else if s[pos] == '"' { pos += 1; break } else { pos += 1 }
            }
            continue
        }
        if s[pos] == '{' { depth += 1 }
        else if s[pos] == '}' {
            depth -= 1
            if depth == 0 { return pos }
        }
        pos += 1
    }
    return len(s) - 1
}

// find_matching_bracket finds the index of the closing ] that matches the [ at pos
find_matching_bracket :: proc(s: string, start: int) -> int {
    depth := 0
    pos := start
    for pos < len(s) {
        if s[pos] == '"' {
            pos += 1
            for pos < len(s) {
                if s[pos] == '\\' { pos += 2 } else if s[pos] == '"' { pos += 1; break } else { pos += 1 }
            }
            continue
        }
        if s[pos] == '[' { depth += 1 }
        else if s[pos] == ']' {
            depth -= 1
            if depth == 0 { return pos }
        }
        pos += 1
    }
    return len(s) - 1
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
    msg := Message{role = "assistant"}
    tool_calls_list := make([dynamic]ToolCall)

    // Find standalone "content" key (skip keys like "reasoning_content")
    content_idx := -1
    search_pos := 0
    for {
        idx := strings.index(body[search_pos:], `"content"`)
        if idx < 0 { break }
        actual := search_pos + idx
        if actual > 0 {
            prev := body[actual - 1]
            if (prev >= 'a' && prev <= 'z') || (prev >= 'A' && prev <= 'Z') || prev == '_' {
                search_pos = actual + 9
                continue
            }
        }
        content_idx = actual
        break
    }

    if content_idx >= 0 {
        search_start := content_idx + 9 // len(`"content"`) = 9
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
                msg.content = strings.clone(body[search_start:end])
            }
        } else if search_start < len(body) && body[search_start] == 'n' {
            // content: null — this is normal when tool_calls are present
            msg.content = ""
        }
    }

    // Parse tool_calls array from OpenAI response
    // Format: "tool_calls":[{"id":"call_xxx","type":"function","function":{"name":"...","arguments":"..."}}]
    tc_idx := strings.index(body, `"tool_calls"`)
    if tc_idx >= 0 {
        // Find the array start
        arr_pos := tc_idx + len(`"tool_calls"`)
        for arr_pos < len(body) && body[arr_pos] != '[' {
            arr_pos += 1
        }
        if arr_pos < len(body) {
            arr_pos += 1 // skip '['
            // Parse each tool call object in the array
            for arr_pos < len(body) && body[arr_pos] != ']' {
                // Find next object
                obj_start := strings.index(body[arr_pos:], "{")
                if obj_start < 0 { break }
                arr_pos += obj_start

                // Extract "id"
                tc_id := extract_json_string(body[arr_pos:], "id")

                // Find the "function" object
                fn_idx := strings.index(body[arr_pos:], `"function"`)
                if fn_idx < 0 { break }
                fn_pos := arr_pos + fn_idx

                // Extract function name and arguments
                fn_name := extract_json_string(body[fn_pos:], "name")
                fn_args_raw := extract_json_string(body[fn_pos:], "arguments")

                if fn_name != "" {
                    tc := ToolCall{
                        id   = strings.clone(tc_id),
                        name = strings.clone(fn_name),
                        arguments = parse_json_arguments(fn_args_raw),
                    }
                    append(&tool_calls_list, tc)
                }

                // Skip past this tool call object (find matching closing brace)
                // Find the end of the "function" sub-object, then skip the outer object
                depth := 0
                skip_pos := arr_pos
                found_start := false
                for skip_pos < len(body) {
                    if body[skip_pos] == '"' {
                        // Skip over string contents
                        skip_pos += 1
                        for skip_pos < len(body) {
                            if body[skip_pos] == '\\' {
                                skip_pos += 2
                            } else if body[skip_pos] == '"' {
                                skip_pos += 1
                                break
                            } else {
                                skip_pos += 1
                            }
                        }
                        continue
                    }
                    if body[skip_pos] == '{' {
                        depth += 1
                        found_start = true
                    } else if body[skip_pos] == '}' {
                        depth -= 1
                        if found_start && depth == 0 {
                            skip_pos += 1
                            break
                        }
                    }
                    skip_pos += 1
                }
                arr_pos = skip_pos
            }
        }
    }

    return msg, tool_calls_list[:], .None
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
    strings.write_string(&sb, `"`)

    // Extract system message for Anthropic's system parameter
    for msg in messages {
        if msg.role == "system" {
            escaped := escape_json_string(msg.content)
            defer delete(escaped)
            strings.write_string(&sb, `,"system":"`)
            strings.write_string(&sb, escaped)
            strings.write_string(&sb, `"`)
            break
        }
    }

    strings.write_string(&sb, `,"messages":[`)

    first := true
    for msg in messages {
        // Skip system messages - they go in system parameter above
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

    strings.write_string(&sb, `]`)

    // Add tool definitions for Anthropic format
    if len(tools) > 0 {
        strings.write_string(&sb, `,"tools":[`)
        first_tool := true
        for tool in tools {
            if tool.vtable.schema == nil {
                continue
            }
            if !first_tool {
                strings.write_string(&sb, ",")
            }
            first_tool = false

            name := tool.vtable.name(tool.ptr)
            desc := tool.vtable.description(tool.ptr)
            schema := tool.vtable.schema(tool.ptr)
            escaped_desc := escape_json_string(desc)
            defer delete(escaped_desc)

            strings.write_string(&sb, `{"name":"`)
            strings.write_string(&sb, name)
            strings.write_string(&sb, `","description":"`)
            strings.write_string(&sb, escaped_desc)
            strings.write_string(&sb, `","input_schema":`)
            strings.write_string(&sb, schema)
            strings.write_string(&sb, `}`)
        }
        strings.write_string(&sb, `]`)
    }

    strings.write_string(&sb, `,"max_tokens":4096}`)

    return strings.clone(strings.to_string(sb))
}

anthropic_http_post :: proc(url: string, body: string, api_key: string, model: string) -> (string, Provider_Error) {
    headers := []string{
        fmt.tprintf("x-api-key: %s", api_key),
        "anthropic-version: 2023-06-01",
        "Content-Type: application/json",
    }
    resp, err := http_post_request(url, body, headers)
    if err != .None {
        return "", .Network_Error
    }
    defer delete(resp.body)
    if resp.status_code < 200 || resp.status_code >= 300 {
        return "", .API_Error
    }
    return strings.clone(resp.body), .None
}

parse_anthropic_response :: proc(body: string) -> (Message, []ToolCall, AgentError) {
    msg := Message{role = "assistant"}
    tool_calls_list := make([dynamic]ToolCall)

    // Anthropic returns content as array: "content":[{"type":"text","text":"..."},{"type":"tool_use","id":"...","name":"...","input":{...}}]
    // First, extract text content blocks
    text_content := strings.builder_make()
    defer strings.builder_destroy(&text_content)

    // Find the content array
    content_arr_idx := strings.index(body, `"content"`)
    if content_arr_idx >= 0 {
        pos := content_arr_idx + len(`"content"`)
        // Skip to array start
        for pos < len(body) && body[pos] != '[' {
            pos += 1
        }
        if pos < len(body) {
            pos += 1 // skip '['

            // Scan through content blocks
            for pos < len(body) && body[pos] != ']' {
                // Find next object
                obj_idx := strings.index(body[pos:], "{")
                if obj_idx < 0 { break }
                pos += obj_idx

                // Determine the block type
                block_type := extract_json_string(body[pos:], "type")

                if block_type == "text" {
                    // Extract the text value
                    text_val := extract_json_string(body[pos:], "text")
                    if text_val != "" {
                        if strings.builder_len(text_content) > 0 {
                            strings.write_string(&text_content, "\n")
                        }
                        strings.write_string(&text_content, text_val)
                    }
                } else if block_type == "tool_use" {
                    // Extract tool use fields
                    tc_id := extract_json_string(body[pos:], "id")
                    tc_name := extract_json_string(body[pos:], "name")

                    // Extract the "input" object as raw JSON and parse arguments
                    input_idx := strings.index(body[pos:], `"input"`)
                    args := make(map[string]json.Value)
                    if input_idx >= 0 {
                        input_pos := pos + input_idx + len(`"input"`)
                        // Skip to the object start
                        for input_pos < len(body) && body[input_pos] != '{' {
                            input_pos += 1
                        }
                        if input_pos < len(body) {
                            // Find matching closing brace
                            input_end := find_matching_brace(body, input_pos)
                            if input_end > input_pos {
                                input_json := body[input_pos:input_end + 1]
                                args = parse_json_arguments(input_json)
                            }
                        }
                    }

                    if tc_name != "" {
                        tc := ToolCall{
                            id        = strings.clone(tc_id),
                            name      = strings.clone(tc_name),
                            arguments = args,
                        }
                        append(&tool_calls_list, tc)
                    }
                }

                // Skip past this content block object
                depth := 0
                found_start := false
                for pos < len(body) {
                    if body[pos] == '"' {
                        pos += 1
                        for pos < len(body) {
                            if body[pos] == '\\' {
                                pos += 2
                            } else if body[pos] == '"' {
                                pos += 1
                                break
                            } else {
                                pos += 1
                            }
                        }
                        continue
                    }
                    if body[pos] == '{' {
                        depth += 1
                        found_start = true
                    } else if body[pos] == '}' {
                        depth -= 1
                        if found_start && depth == 0 {
                            pos += 1
                            break
                        }
                    }
                    pos += 1
                }
            }
        }
    }

    msg.content = strings.clone(strings.to_string(text_content))
    return msg, tool_calls_list[:], .None
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
    return strings.clone(strings.to_string(sb))
}

parse_ollama_response :: proc(body: string) -> (Message, []ToolCall, AgentError) {
    msg := Message{role = "assistant"}
    tool_calls := make([]ToolCall, 0)

    if content_idx := strings.index(body, `"content"`); content_idx >= 0 {
        search_start := content_idx + 9 // len(`"content"`) = 9
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
                msg.content = strings.clone(body[search_start:end])
            }
        }
    }

    return msg, tool_calls, .None
}

// ============================================================================
// Gemini Provider (Google AI Studio)
// ============================================================================

GeminiProvider :: struct {
    api_key:  string,
    model:    string,
    endpoint: string,
}

init_gemini_provider :: proc(api_key: string, model: string) -> Provider {
    prov := new(GeminiProvider)
    prov.api_key = api_key
    prov.model = model
    prov.endpoint = "https://generativelanguage.googleapis.com/v1beta"
    return Provider{ptr = prov, vtable = &gemini_vtable}
}

gemini_vtable := Provider_VTable{
    chat = gemini_chat,
    name = gemini_name,
    deinit = gemini_deinit,
}

gemini_name :: proc(ptr: rawptr) -> string {
    prov := (^GeminiProvider)(ptr)
    return fmt.tprintf("gemini:%s", prov.model)
}

gemini_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

gemini_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    prov := (^GeminiProvider)(ptr)

    request_body := build_gemini_request(messages, tools, prov.model)
    defer delete(request_body)

    url := fmt.tprintf("%s/models/%s:generateContent?key=%s", prov.endpoint, prov.model, prov.api_key)

    headers := []string{"Content-Type: application/json"}
    resp, err := http_post_request(url, request_body, headers)
    if err != .None {
        return Message{}, {}, .ProviderError
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        return Message{}, {}, .ProviderError
    }

    return parse_gemini_response(resp.body)
}

build_gemini_request :: proc(messages: []Message, tools: []Tool, model: string) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    // Extract system instruction
    system_content := ""
    for msg in messages {
        if msg.role == "system" {
            system_content = msg.content
            break
        }
    }

    strings.write_string(&sb, `{`)

    // System instruction
    if system_content != "" {
        escaped := escape_json_string(system_content)
        defer delete(escaped)
        strings.write_string(&sb, `"system_instruction":{"parts":[{"text":"`)
        strings.write_string(&sb, escaped)
        strings.write_string(&sb, `"}]},`)
    }

    // Contents (conversation turns)
    strings.write_string(&sb, `"contents":[`)
    first := true
    for msg in messages {
        if msg.role == "system" { continue }

        if !first { strings.write_string(&sb, ",") }
        first = false

        // Gemini uses "user" and "model" roles
        role := msg.role == "assistant" ? "model" : "user"

        escaped := escape_json_string(msg.content)
        defer delete(escaped)

        strings.write_string(&sb, `{"role":"`)
        strings.write_string(&sb, role)
        strings.write_string(&sb, `","parts":[{"text":"`)
        strings.write_string(&sb, escaped)
        strings.write_string(&sb, `"}]}`)
    }
    strings.write_string(&sb, `]`)

    // Tool declarations
    if len(tools) > 0 {
        strings.write_string(&sb, `,"tools":[{"function_declarations":[`)
        first_tool := true
        for tool in tools {
            if tool.vtable.schema == nil { continue }
            if !first_tool { strings.write_string(&sb, ",") }
            first_tool = false

            name := tool.vtable.name(tool.ptr)
            desc := tool.vtable.description(tool.ptr)
            schema := tool.vtable.schema(tool.ptr)
            escaped_desc := escape_json_string(desc)
            defer delete(escaped_desc)

            strings.write_string(&sb, `{"name":"`)
            strings.write_string(&sb, name)
            strings.write_string(&sb, `","description":"`)
            strings.write_string(&sb, escaped_desc)
            strings.write_string(&sb, `","parameters":`)
            strings.write_string(&sb, schema)
            strings.write_string(&sb, `}`)
        }
        strings.write_string(&sb, `]}]`)
    }

    strings.write_string(&sb, `,"generationConfig":{"maxOutputTokens":4096}}`)

    return strings.clone(strings.to_string(sb))
}

parse_gemini_response :: proc(body: string) -> (Message, []ToolCall, AgentError) {
    msg := Message{role = "assistant"}
    tool_calls_list := make([dynamic]ToolCall)

    // Gemini response: {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}
    // Or with tool calls: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"...","args":{...}}}]}}]}

    // Find the parts array
    parts_idx := strings.index(body, `"parts"`)
    if parts_idx < 0 {
        return msg, tool_calls_list[:], .None
    }

    // Find array start
    arr_start := parts_idx + len(`"parts"`)
    for arr_start < len(body) && body[arr_start] != '[' {
        arr_start += 1
    }
    if arr_start >= len(body) {
        return msg, tool_calls_list[:], .None
    }

    text_content := strings.builder_make()
    defer strings.builder_destroy(&text_content)

    pos := arr_start + 1
    for pos < len(body) && body[pos] != ']' {
        obj_idx := strings.index(body[pos:], "{")
        if obj_idx < 0 { break }
        pos += obj_idx

        // Check if this is a text part or functionCall part
        if fc_idx := strings.index(body[pos:pos+100 < len(body) ? pos+100 : len(body)], `"functionCall"`); fc_idx >= 0 && fc_idx < 50 {
            // Function call part
            fc_pos := pos + fc_idx
            fn_name := extract_json_string(body[fc_pos:], "name")

            // Extract args object
            args_idx := strings.index(body[fc_pos:], `"args"`)
            args := make(map[string]json.Value)
            if args_idx >= 0 {
                args_pos := fc_pos + args_idx + len(`"args"`)
                for args_pos < len(body) && body[args_pos] != '{' {
                    args_pos += 1
                }
                if args_pos < len(body) {
                    args_end := find_matching_brace(body, args_pos)
                    args = parse_json_arguments(body[args_pos:args_end+1])
                }
            }

            if fn_name != "" {
                append(&tool_calls_list, ToolCall{
                    id        = fmt.tprintf("gemini_call_%d", len(tool_calls_list)),
                    name      = strings.clone(fn_name),
                    arguments = args,
                })
            }
        } else {
            // Text part
            text_val := extract_json_string(body[pos:], "text")
            if text_val != "" {
                if strings.builder_len(text_content) > 0 {
                    strings.write_string(&text_content, "\n")
                }
                strings.write_string(&text_content, text_val)
            }
        }

        // Skip to next part
        end := find_matching_brace(body, pos)
        pos = end + 1
    }

    msg.content = strings.clone(strings.to_string(text_content))
    return msg, tool_calls_list[:], .None
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

// Lazy-initialized compatible provider endpoints
@(private)
compatible_endpoints_cache: map[string]string

get_compatible_endpoints :: proc() -> ^map[string]string {
    if len(compatible_endpoints_cache) == 0 {
        compatible_endpoints_cache = map[string]string{
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
    }
    return &compatible_endpoints_cache
}

get_compatible_endpoint :: proc(provider_name: string) -> string {
    endpoints := get_compatible_endpoints()
    if ep, ok := endpoints^[provider_name]; ok {
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
    defer delete(response_body)

    return parse_openai_response(response_body)
}

