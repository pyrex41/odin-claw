package main

import "core:fmt"
import "core:strings"
import "core:time"

// InboundMessage represents a message from any channel
InboundMessage :: struct {
    channel:   string, // "telegram", "cli", "slack", "discord", etc.
    user_id:   string,
    text:      string,
    timestamp: i64,
    metadata:  map[string]string, // channel-specific metadata (e.g. chat_id for telegram)
}

// OutboundMessage represents a response to send back
OutboundMessage :: struct {
    channel: string,
    user_id: string,
    text:    string,
    metadata: map[string]string,
}

// Dispatcher routes messages from all channels through the agent
Dispatcher :: struct {
    config:        ^Config,
    provider:      Provider,
    tools:         []Tool,
    session_store: ^SessionStore,
    cost_tracker:  ^CostTracker,
}

init_dispatcher :: proc(
    config: ^Config,
    provider: Provider,
    tools: []Tool,
    session_store: ^SessionStore,
) -> ^Dispatcher {
    d := new(Dispatcher)
    d.config = config
    d.provider = provider
    d.tools = tools
    d.session_store = session_store
    d.cost_tracker = init_cost_tracker(0) // 0 = no budget limit
    return d
}

deinit_dispatcher :: proc(d: ^Dispatcher) {
    if d.cost_tracker != nil {
        fmt.printf("[Dispatcher] Session stats: %s\n", format_usage(d.cost_tracker, d.config.providers.default_model))
        deinit_cost_tracker(d.cost_tracker)
    }
    free(d)
}

// dispatch processes an inbound message and returns the response text
dispatch :: proc(d: ^Dispatcher, msg: InboundMessage) -> string {
    fmt.printf("[Dispatch] %s:%s -> %s\n", msg.channel, msg.user_id, msg.text)

    // Check budget
    if d.cost_tracker != nil && is_over_budget(d.cost_tracker, d.config.providers.default_model) {
        return "Budget limit reached. Please try again later."
    }

    // Load or create session
    session := load_session(d.session_store, msg.channel, msg.user_id)

    // Build system prompt
    system_prompt := build_system_prompt(d.tools, msg.channel)

    // Create agent
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    agent := init_agent(d.config, d.provider, d.tools, runtime)
    defer deinit_agent(agent)

    // Load system prompt
    append(&agent.memory, Message{role = "system", content = system_prompt})

    // Load session history
    for hist_msg in session.history {
        append(&agent.memory, Message{role = hist_msg.role, content = hist_msg.content})
    }

    // Run agent
    reply, err := chat_loop(agent, msg.text, d.config.agent.max_loop_iterations)
    if err != .None {
        fmt.printf("[Dispatch] Agent error: %v\n", err)
        reply = "Sorry, I couldn't process that request."
    }

    // Update session from agent memory
    for m in session.history {
        delete(m.role)
        delete(m.content)
    }
    clear(&session.history)
    for m in agent.memory {
        if m.role != "system" {
            append(&session.history, Message{role = strings.clone(m.role), content = strings.clone(m.content)})
        }
    }
    save_session(d.session_store, &session)

    // Estimate token usage from message lengths
    if d.cost_tracker != nil {
        input_est := 0
        for m in agent.memory {
            input_est += len(m.content) / 4
        }
        output_est := len(reply) / 4
        record_usage(d.cost_tracker, UsageInfo{
            input_tokens = input_est,
            output_tokens = output_est,
            total_tokens = input_est + output_est,
        })
    }

    fmt.printf("[Dispatch] Reply (%d chars): %.100s%s\n",
        len(reply), reply, len(reply) > 100 ? "..." : "")

    return reply
}

// dispatch_telegram is a convenience wrapper for Telegram webhook processing
dispatch_telegram :: proc(d: ^Dispatcher, chat_id: string, text: string) -> string {
    metadata := make(map[string]string)
    metadata["chat_id"] = chat_id

    msg := InboundMessage{
        channel   = "telegram",
        user_id   = chat_id,
        text      = text,
        timestamp = time.time_to_unix(time.now()),
        metadata  = metadata,
    }

    reply := dispatch(d, msg)
    delete(metadata)
    return reply
}
