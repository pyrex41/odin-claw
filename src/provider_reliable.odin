package main

import "core:fmt"
import "core:strings"
import "core:time"

// ReliableProvider wraps a primary provider with retry logic and optional fallback
ReliableProvider :: struct {
    primary:     Provider,
    fallback:    Provider, // Optional fallback provider (ptr can be nil)
    max_retries: int,
    base_delay:  i64, // milliseconds
    has_fallback: bool,
}

init_reliable_provider :: proc(primary: Provider, fallback: Provider, max_retries: int, has_fallback: bool) -> Provider {
    rp := new(ReliableProvider)
    rp.primary = primary
    rp.fallback = fallback
    rp.max_retries = max_retries > 0 ? max_retries : 3
    rp.base_delay = 500 // 500ms base delay
    rp.has_fallback = has_fallback
    return Provider{ptr = rp, vtable = &reliable_vtable}
}

reliable_vtable := Provider_VTable{
    chat   = reliable_chat,
    name   = reliable_name,
    deinit = reliable_deinit,
}

reliable_name :: proc(ptr: rawptr) -> string {
    rp := (^ReliableProvider)(ptr)
    return fmt.tprintf("reliable(%s)", rp.primary.vtable.name(rp.primary.ptr))
}

reliable_deinit :: proc(ptr: rawptr) {
    rp := (^ReliableProvider)(ptr)
    rp.primary.vtable.deinit(rp.primary.ptr)
    if rp.has_fallback {
        rp.fallback.vtable.deinit(rp.fallback.ptr)
    }
    free(rp)
}

reliable_chat :: proc(ptr: rawptr, messages: []Message, tools: []Tool) -> (Message, []ToolCall, AgentError) {
    rp := (^ReliableProvider)(ptr)

    // Try primary provider with exponential backoff
    for attempt := 0; attempt <= rp.max_retries; attempt += 1 {
        if attempt > 0 {
            // Exponential backoff: base_delay * 2^(attempt-1)
            delay_ms := rp.base_delay
            for i := 1; i < attempt; i += 1 {
                delay_ms *= 2
            }
            // Cap at 30 seconds
            if delay_ms > 30000 {
                delay_ms = 30000
            }
            fmt.printf("[Reliable] Retry %d/%d after %dms delay\n", attempt, rp.max_retries, delay_ms)
            time.sleep(time.Duration(delay_ms) * time.Millisecond)
        }

        msg, tool_calls, err := rp.primary.vtable.chat(rp.primary.ptr, messages, tools)
        if err == .None {
            return msg, tool_calls, .None
        }

        fmt.printf("[Reliable] Primary provider failed (attempt %d/%d): %v\n",
            attempt + 1, rp.max_retries + 1, err)
    }

    // Try fallback provider if available
    if rp.has_fallback {
        fmt.printf("[Reliable] Falling back to secondary provider: %s\n",
            rp.fallback.vtable.name(rp.fallback.ptr))
        msg, tool_calls, err := rp.fallback.vtable.chat(rp.fallback.ptr, messages, tools)
        if err == .None {
            return msg, tool_calls, .None
        }
        fmt.printf("[Reliable] Fallback provider also failed: %v\n", err)
    }

    return Message{}, {}, .ProviderError
}
