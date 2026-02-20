package main

import "base:runtime"
import "core:fmt"
import "core:strings"

// SSE_Event represents a Server-Sent Event
SSE_Event :: struct {
    event: string, // event type (e.g., "message", "content_block_delta")
    data:  string, // event data (often JSON)
    id:    string, // optional event ID
}

// SSE_Parser parses an SSE stream incrementally
SSE_Parser :: struct {
    buffer:     strings.Builder,
    events:     [dynamic]SSE_Event,
    current_event: string,
    current_data:  strings.Builder,
    current_id:    string,
}

init_sse_parser :: proc() -> ^SSE_Parser {
    p := new(SSE_Parser)
    p.buffer = strings.builder_make()
    p.events = make([dynamic]SSE_Event)
    p.current_data = strings.builder_make()
    return p
}

deinit_sse_parser :: proc(p: ^SSE_Parser) {
    strings.builder_destroy(&p.buffer)
    strings.builder_destroy(&p.current_data)
    delete(p.events)
    free(p)
}

// feed pushes raw bytes into the parser and extracts complete events
feed_sse :: proc(p: ^SSE_Parser, data: []byte) {
    strings.write_bytes(&p.buffer, data)

    // Process complete lines
    for {
        buf_str := strings.to_string(p.buffer)
        nl_idx := strings.index(buf_str, "\n")
        if nl_idx < 0 {
            break
        }

        line := buf_str[:nl_idx]
        // Remove \r if present
        if len(line) > 0 && line[len(line)-1] == '\r' {
            line = line[:len(line)-1]
        }

        // Consume the line from the buffer
        remaining := buf_str[nl_idx + 1:]
        new_buf := strings.builder_make()
        strings.write_string(&new_buf, remaining)
        strings.builder_destroy(&p.buffer)
        p.buffer = new_buf

        // Process the line
        if len(line) == 0 {
            // Empty line = dispatch the event
            if strings.builder_len(p.current_data) > 0 {
                event := SSE_Event{
                    event = strings.clone(p.current_event != "" ? p.current_event : "message"),
                    data  = strings.clone(strings.to_string(p.current_data)),
                    id    = strings.clone(p.current_id),
                }
                append(&p.events, event)
            }
            // Reset for next event
            strings.builder_reset(&p.current_data)
            p.current_event = ""
            p.current_id = ""
        } else if strings.has_prefix(line, "data:") {
            value := line[5:]
            if len(value) > 0 && value[0] == ' ' {
                value = value[1:]
            }
            if strings.builder_len(p.current_data) > 0 {
                strings.write_byte(&p.current_data, '\n')
            }
            strings.write_string(&p.current_data, value)
        } else if strings.has_prefix(line, "event:") {
            value := line[6:]
            if len(value) > 0 && value[0] == ' ' {
                value = value[1:]
            }
            p.current_event = value
        } else if strings.has_prefix(line, "id:") {
            value := line[3:]
            if len(value) > 0 && value[0] == ' ' {
                value = value[1:]
            }
            p.current_id = value
        }
        // Lines starting with : are comments, ignored
    }
}

// drain_events returns all accumulated events and clears the internal list
drain_events :: proc(p: ^SSE_Parser) -> []SSE_Event {
    result := make([]SSE_Event, len(p.events))
    for i := 0; i < len(p.events); i += 1 {
        result[i] = p.events[i]
    }
    clear(&p.events)
    return result
}

// StreamAccumulator accumulates streaming tokens into a complete response
StreamAccumulator :: struct {
    content:     strings.Builder,
    tool_calls:  [dynamic]ToolCall,
    is_done:     bool,
    usage:       UsageInfo,
}

init_stream_accumulator :: proc() -> ^StreamAccumulator {
    a := new(StreamAccumulator)
    a.content = strings.builder_make()
    a.tool_calls = make([dynamic]ToolCall)
    return a
}

deinit_stream_accumulator :: proc(a: ^StreamAccumulator) {
    strings.builder_destroy(&a.content)
    delete(a.tool_calls)
    free(a)
}

// process_openai_stream_event handles a single SSE event from OpenAI streaming
process_openai_stream_event :: proc(acc: ^StreamAccumulator, event: SSE_Event) {
    if event.data == "[DONE]" {
        acc.is_done = true
        return
    }

    // Extract delta content: "delta":{"content":"..."}
    delta_idx := strings.index(event.data, `"delta"`)
    if delta_idx >= 0 {
        content_val := extract_json_string(event.data[delta_idx:], "content")
        if content_val != "" {
            strings.write_string(&acc.content, content_val)
        }
    }

    // Check for usage in the final event
    if strings.contains(event.data, `"usage"`) {
        acc.usage = parse_usage_from_openai(event.data)
    }
}

// process_anthropic_stream_event handles a single SSE event from Anthropic streaming
process_anthropic_stream_event :: proc(acc: ^StreamAccumulator, event: SSE_Event) {
    switch event.event {
    case "content_block_delta":
        // {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"..."}}
        text_val := extract_json_string(event.data, "text")
        if text_val != "" {
            strings.write_string(&acc.content, text_val)
        }
    case "message_stop":
        acc.is_done = true
    case "message_delta":
        // May contain usage
        if strings.contains(event.data, `"usage"`) {
            acc.usage = parse_usage_from_anthropic(event.data)
        }
    }
}

// get_accumulated_content returns the content built up so far
get_accumulated_content :: proc(acc: ^StreamAccumulator) -> string {
    return strings.to_string(acc.content)
}

// Streaming write callback for libcurl
Stream_Write_Context :: struct {
    parser: ^SSE_Parser,
    acc:    ^StreamAccumulator,
    provider_type: string, // "openai" or "anthropic"
    ctx:    runtime.Context,
}

stream_write_callback :: proc "c" (ptr: [^]u8, size: uint, nmemb: uint, userdata: rawptr) -> uint {
    total := size * nmemb
    swc := (^Stream_Write_Context)(userdata)
    context = swc.ctx

    feed_sse(swc.parser, ptr[:total])

    // Process any complete events
    events := drain_events(swc.parser)
    defer delete(events)

    for event in events {
        if swc.provider_type == "anthropic" {
            process_anthropic_stream_event(swc.acc, event)
        } else {
            process_openai_stream_event(swc.acc, event)
        }
    }

    return total
}
