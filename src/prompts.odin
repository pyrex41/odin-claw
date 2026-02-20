package main

import "core:fmt"
import "core:strings"
import "core:time"

// build_system_prompt generates a context-rich system prompt
build_system_prompt :: proc(tools: []Tool, channel: string) -> string {
    sb := strings.builder_make()

    // Identity
    strings.write_string(&sb, "You are OdinClaw, an AI assistant built with Odin. ")
    strings.write_string(&sb, "You are helpful, accurate, and concise.\n\n")

    // Current date/time
    now := time.now()
    year, month, day := time.date(now)
    hour, minute, second := time.clock(now)
    strings.write_string(&sb, fmt.tprintf("Current date and time: %d-%02d-%02d %02d:%02d:%02d UTC\n\n",
        year, int(month), day, hour, minute, second))

    // Channel context
    if channel != "" {
        strings.write_string(&sb, fmt.tprintf("You are communicating via the %s channel.\n", channel))
    }

    // Available tools
    if len(tools) > 0 {
        strings.write_string(&sb, "You have access to the following tools:\n")
        for tool in tools {
            name := tool.vtable.name(tool.ptr)
            desc := tool.vtable.description(tool.ptr)
            strings.write_string(&sb, fmt.tprintf("- %s: %s\n", name, desc))
        }
        strings.write_string(&sb, "\nTo use a tool, respond with a tool_call. ")
        strings.write_string(&sb, "Only use tools when needed to answer the user's question.\n")
    }

    strings.write_string(&sb, "\nBe direct and helpful. If you don't know something, say so rather than guessing.")

    return strings.to_string(sb)
}
