package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

// Message represents a chat message
Message :: struct {
    role:    string, // "system", "user", "assistant", "tool"
    content: string,
}

// ToolCall represents a tool invocation
ToolCall :: struct {
    id:       string,
    name:     string,
    arguments: map[string]json.Value,
}

// Error types for agent operations
AgentError :: enum {
    None,
    ProviderError,
    ToolError,
    MemoryFull,
    SubagentLimitExceeded,
}





// Agent represents the agent orchestration system
Agent :: struct {
    config:      ^Config,
    provider:    Provider,
    tools:      []Tool,
    runtime:     Runtime,
    memory:      [dynamic]Message, // conversation history
    subagents:   [dynamic]^Agent,  // spawned subagents
    compaction_threshold: int,
}

// init_agent initializes a new agent
init_agent :: proc(config: ^Config, provider: Provider, tools: []Tool, runtime: Runtime) -> ^Agent {
    agent := new(Agent)
    agent.config = config
    agent.provider = provider
    agent.tools = tools
    agent.runtime = runtime
    agent.memory = make([dynamic]Message, 0)
    agent.subagents = make([dynamic]^Agent, 0)
    agent.compaction_threshold = config.agent.compaction_threshold
    return agent
}

// deinit_agent cleans up agent resources
deinit_agent :: proc(agent: ^Agent) {
    agent.runtime.vtable.deinit(&agent.runtime)
    delete(agent.memory)
    for sub in agent.subagents {
        deinit_agent(sub)
    }
    delete(agent.subagents)
    free(agent)
}

// compact_memory compacts the agent's memory by summarizing old messages
compact_memory :: proc(agent: ^Agent) {
    if len(agent.memory) < agent.compaction_threshold {
        return
    }

    // Simple compaction: keep last 10 messages, summarize the rest
    keep_count := 10
    if len(agent.memory) <= keep_count {
        return
    }

    summary := Message{
        role = "system",
        content = fmt.tprintf("Conversation summary: %d messages compacted", len(agent.memory) - keep_count),
    }

    new_memory := make([dynamic]Message, 0, 1 + keep_count)
    append(&new_memory, summary)
    append(&new_memory, ..agent.memory[len(agent.memory)-keep_count:])
    delete(agent.memory)
    agent.memory = new_memory
}

// dispatch_tool executes a tool call
dispatch_tool :: proc(agent: ^Agent, tool_call: ToolCall) -> (result: Result, err: AgentError) {
    for tool in agent.tools {
        if tool.vtable.name(tool.ptr) == tool_call.name {
            return tool.vtable.execute(tool.ptr, tool_call.arguments, agent.config, &agent.runtime), .None
        }
    }
    return Result{}, .ToolError
}

// spawn_subagent creates a new subagent
spawn_subagent :: proc(parent: ^Agent, task: string) -> (^Agent, AgentError) {
    if len(parent.subagents) >= parent.config.agent.subagent_limit {
        return nil, .SubagentLimitExceeded
    }

    subagent := init_agent(parent.config, parent.provider, parent.tools, parent.runtime)
    // Initialize with task
    append(&subagent.memory, Message{role = "system", content = task})

    append(&parent.subagents, subagent)
    return subagent, .None
}

// chat_loop runs the main agent chat loop
chat_loop :: proc(agent: ^Agent, user_message: string, max_iterations: int) -> (response: string, err: AgentError) {
    // Add user message
    append(&agent.memory, Message{role = "user", content = user_message})

    for i := 0; i < max_iterations; i += 1 {
        compact_memory(agent)

        // Call provider
        response_msg, tool_calls, provider_err := agent.provider.vtable.chat(agent.provider.ptr, agent.memory[:], agent.tools)
        if provider_err != .None {
            // Error recovery: retry up to config.agent.recovery_attempts
            for attempt := 0; attempt < agent.config.agent.recovery_attempts; attempt += 1 {
                response_msg, tool_calls, provider_err = agent.provider.vtable.chat(agent.provider.ptr, agent.memory[:], agent.tools)
                if provider_err == .None {
                    break
                }
            }
            if provider_err != .None {
                return "", .ProviderError
            }
        }

        append(&agent.memory, response_msg)

        if len(tool_calls) == 0 {
            return response_msg.content, .None
        }

        // Dispatch tool calls
        for tool_call in tool_calls {
            tool_result, tool_err := dispatch_tool(agent, tool_call)
            if tool_err != .None {
                return "", tool_err
            }

            // Add tool result to memory
            tool_msg := Message{
                role = "tool",
                content = tool_result.(string) or_else "Tool executed",
            }
            append(&agent.memory, tool_msg)
        }

        // Get final response after tool execution
        response_msg, tool_calls, provider_err = agent.provider.vtable.chat(agent.provider.ptr, agent.memory[:], agent.tools)
        if provider_err != .None {
            return "", .ProviderError
        }
        append(&agent.memory, response_msg)

        if len(tool_calls) == 0 {
            return response_msg.content, .None
        }
        // If still tool calls, continue loop
    }

    return "Max iterations reached", .None
}





mock_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    return "mock result"
}

mock_tool_name :: proc(ptr: rawptr) -> string {
    return "mock_tool"
}

mock_tool_description :: proc(ptr: rawptr) -> string {
    return "Mock tool"
}

mock_tool_vtable := Tool_VTable{
    execute = mock_tool_execute,
    name = mock_tool_name,
    description = mock_tool_description,
}