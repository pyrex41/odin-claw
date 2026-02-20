package main

import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:testing"

// Tests for agent functionality

@test
test_agent_init :: proc(t: ^testing.T) {
    config := default_config()
    // Mock provider
    mock_provider := init_mock_provider("test", "mock response")
    defer mock_provider.vtable.deinit(mock_provider.ptr)
    tools := []Tool{}
    runtime := create_native_runtime()

    agent := init_agent(&config, mock_provider, tools, runtime)
    defer deinit_agent(agent)

    testing.expect(t, agent.config == &config, "Config should be set")
    testing.expect(t, len(agent.memory) == 0, "Memory should be empty")
}

@test
test_compact_memory :: proc(t: ^testing.T) {
    config := default_config()
    config.agent.compaction_threshold = 5
    mock_provider := init_mock_provider("test", "mock response")
    defer mock_provider.vtable.deinit(mock_provider.ptr)
    tools := []Tool{}
    runtime := create_native_runtime()

    agent := init_agent(&config, mock_provider, tools, runtime)
    defer deinit_agent(agent)

    // Add many messages
    for i := 0; i < 11; i += 1 {
        append(&agent.memory, Message{role = "user", content = fmt.tprintf("msg %d", i)})
    }

    compact_memory(agent)

    testing.expect(t, len(agent.memory) == 11, "Should have summary + last 10") // 1 summary + 10 kept
    testing.expect(t, strings.contains(agent.memory[0].content, "compacted"), "First message should be summary")
}

@test
test_dispatch_tool :: proc(t: ^testing.T) {
    config := default_config()
    mock_provider := init_mock_provider("test", "mock response")
    defer mock_provider.vtable.deinit(mock_provider.ptr)
    mock_tool := Tool{ptr = nil, vtable = &mock_tool_vtable}
    tools := []Tool{mock_tool}
    runtime := create_native_runtime()

    agent := init_agent(&config, mock_provider, tools, runtime)
    defer deinit_agent(agent)

    tool_call := ToolCall{
        id = "1",
        name = "mock_tool",
        arguments = make(map[string]json.Value),
    }
    defer delete(tool_call.arguments)
    tool_call.arguments["arg"] = json.String("test")

    result, err := dispatch_tool(agent, tool_call)

    testing.expect(t, err == .None, "Should dispatch successfully")
    switch r in result {
    case string:
        testing.expect(t, r == "mock result", "Should return mock result")
    case Error:
        testing.expect(t, false, "Should not error")
    }
}

@test
test_chat_loop :: proc(t: ^testing.T) {
    config := default_config()
    config.agent.max_loop_iterations = 5
    mock_provider := init_mock_provider("mock response", "mock response")
	defer mock_provider.vtable.deinit(mock_provider.ptr)
    tools := get_tools()
    runtime := create_native_runtime()

    agent := init_agent(&config, mock_provider, tools, runtime)
    defer deinit_agent(agent)

    response, err := chat_loop(agent, "Hello", 5)

    testing.expect(t, err == .None, "Chat loop should succeed")
    testing.expect(t, response == "mock response", "Should return mock response")
}