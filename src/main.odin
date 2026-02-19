package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:strings"

Command :: enum {
    Agent,
    Gateway,
    Channel,
    Cron,
    Help,
    None,
}

parse_command :: proc(arg: string) -> Command {
    switch arg {
    case "agent":
        return .Agent
    case "gateway":
        return .Gateway
    case "channel":
        return .Channel
    case "cron":
        return .Cron
    case "help", "--help", "-h":
        return .Help
    case:
        return .None
    }
}

print_usage :: proc() {
    fmt.println("nullclaw - AI assistant runtime")
    fmt.println("")
    fmt.println("USAGE:")
    fmt.println("  nullclaw <command> [options]")
    fmt.println("")
    fmt.println("COMMANDS:")
    fmt.println("  agent       Start the AI agent loop")
    fmt.println("  gateway     Start the HTTP gateway server")
    fmt.println("  channel     Manage messaging channels")
    fmt.println("  cron        Manage scheduled tasks")
    fmt.println("  help        Show this help")
    fmt.println("")
    fmt.println("OPTIONS:")
    fmt.println("  agent:")
    fmt.println("    -m <message>    Send a message to the agent")
    fmt.println("    --provider      Override default provider")
    fmt.println("    --model        Override default model")
    fmt.println("  gateway:")
    fmt.println("    --port <n>     Port (default: 8080)")
    fmt.println("    --host <addr>  Host (default: localhost)")
    fmt.println("  channel:")
    fmt.println("    start          Start all configured channels")
    fmt.println("    list           List configured channels")
}

run_agent :: proc(args: []string) {
    config := load_or_default_config()
    defer free_config(&config)

    tools := get_tools()
    defer delete(tools)

    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    provider := create_provider_from_config(&config)
    defer provider.vtable.deinit(provider.ptr)

    agent := init_agent(&config, provider, tools, runtime)
    defer deinit_agent(agent)

    user_message := ""
    for i := 0; i < len(args); i += 1 {
        if args[i] == "-m" && i + 1 < len(args) {
            user_message = args[i + 1]
            break
        }
    }

    if user_message == "" {
        fmt.println("Entering interactive mode (Ctrl+C to exit)")
        fmt.println("Type your message and press Enter:")
        
        for {
            fmt.print("> ")
            line := read_stdin_line()
            if line == "" {
                break
            }
            
            response, err := chat_loop(agent, line, config.agent.max_loop_iterations)
            if err != .None {
                fmt.printf("Error: %v\n", err)
                continue
            }
            fmt.println(response)
        }
    } else {
        response, err := chat_loop(agent, user_message, config.agent.max_loop_iterations)
        if err != .None {
            fmt.printf("Error: %v\n", err)
            os.exit(1)
        }
        fmt.println(response)
    }
}

run_gateway :: proc(args: []string) {
    config := load_or_default_config()
    defer free_config(&config)

    port := config.gateway.port
    host := config.gateway.host

    for i := 0; i < len(args); i += 1 {
        if args[i] == "--port" && i + 1 < len(args) {
            p := fast_int(args[i + 1])
            if p > 0 {
                port = p
            }
        } else if args[i] == "--host" && i + 1 < len(args) {
            host = args[i + 1]
        }
    }

    tools := get_tools()
    defer delete(tools)

    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    provider := create_provider_from_config(&config)
    defer provider.vtable.deinit(provider.ptr)

    mem := init_in_memory()
    defer deinit_in_memory(mem)

    fmt.printf("Starting gateway on %s:%d\n", host, port)
    start_gateway(&config, host, port, provider, tools, mem)
}

run_channel :: proc(args: []string) {
    config := load_or_default_config()
    defer free_config(&config)

    if len(args) == 0 {
        fmt.println("Usage: nullclaw channel <command>")
        fmt.println("Commands: start, list")
        return
    }

    subcmd := args[0]

    if subcmd == "list" {
        fmt.println("Configured channels:")
        fmt.println("  CLI:       enabled")
        if config.channels.telegram_api_key != "" {
            fmt.println("  Telegram:  configured")
        }
        if config.channels.slack_webhook_url != "" {
            fmt.println("  Slack:     configured")
        }
        if config.channels.discord_token != "" {
            fmt.println("  Discord:   configured")
        }
    } else if subcmd == "start" {
        start_channels(&config)
    } else {
        fmt.printf("Unknown channel command: %s\n", subcmd)
    }
}

run_cron :: proc(args: []string) {
    fmt.println("Cron scheduler not yet implemented")
    fmt.println("Use the agent loop for scheduled tasks")
}

load_or_default_config :: proc() -> Config {
    config_path := "~/.nullclaw/config.json"
    env_path := os.get_env("NULLCLAW_CONFIG_PATH")
    if env_path != "" {
        config_path = env_path
    }
    config, ok := load_from_json(config_path)
    if !ok {
        config = default_config()
    }
    apply_env_overrides(&config)
    return config
}

free_config :: proc(config: ^Config) {
    delete(config.gateway.cors_origins)
    delete(config.tools.allowed_paths)
    delete(config.runtime.allowed_paths)
    delete(config.memory.embedding_provider)
    delete(config.memory.snapshot_path)
    delete(config.channels.allowlist)
}

create_provider_from_config :: proc(config: ^Config) -> Provider {
    prov := config.providers.default_provider
    default_model := config.providers.default_model
    if default_model == "" {
        default_model = "gpt-4o"
    }
    
    if prov == "openai" && config.providers.openai_api_key != "" {
        return init_openai_provider(config.providers.openai_api_key, default_model)
    } else if prov == "xai" && config.providers.xai_api_key != "" {
        model := config.providers.default_model
        if model == "" {
            model = "grok-2"
        }
        return init_xai_provider(config.providers.xai_api_key, model)
    } else if prov == "anthropic" && config.providers.anthropic_api_key != "" {
        model := config.providers.default_model
        if model == "" {
            model = "claude-sonnet-4-20250514"
        }
        return init_anthropic_provider(config.providers.anthropic_api_key, model)
    } else if prov == "ollama" {
        endpoint := config.providers.ollama_endpoint
        if endpoint == "" {
            endpoint = "http://localhost:11434"
        }
        model := config.providers.default_model
        if model == "" {
            model = "llama3"
        }
        return init_ollama_provider(endpoint, model)
    }
    
    return init_mock_provider("mock", "Hello from NullClaw!")
}

read_stdin_line :: proc() -> string {
    buf: [4096]u8
    n, _ := os.read(os.stdin, buf[:])
    if n <= 0 {
        return ""
    }
    if n > 0 && buf[n-1] == '\n' {
        n -= 1
    }
    if n > 0 && buf[n-1] == '\r' {
        n -= 1
    }
    return strings.clone(string(buf[:n]))
}

fast_int :: proc(s: string) -> int {
    result := 0
    for c in s {
        if c < '0' || c > '9' {
            return 0
        }
        result = result * 10 + int(c - '0')
    }
    return result
}

start_channels :: proc(config: ^Config) {
    fmt.println("Starting channels...")
    run_cli_channel(config)
}

run_cli_channel :: proc(config: ^Config) {
    tools := get_tools()
    defer delete(tools)

    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    provider := create_provider_from_config(config)
    defer provider.vtable.deinit(provider.ptr)

    mem := init_in_memory()
    defer deinit_in_memory(mem)

    agent := init_agent(config, provider, tools, runtime)
    defer deinit_agent(agent)

    fmt.println("CLI channel ready. Type your message (Ctrl+C to exit):")
    
    for {
        fmt.print("> ")
        line := read_stdin_line()
        if line == "" {
            break
        }
        
        response, err := chat_loop(agent, line, config.agent.max_loop_iterations)
        if err != .None {
            fmt.printf("Error: %v\n", err)
            continue
        }
        fmt.println(response)
    }
}

main :: proc() {
    args := os.args
    
    if len(args) < 2 {
        print_usage()
        os.exit(1)
    }

    cmd := parse_command(args[1])
    sub_args := args[2:]

    switch cmd {
    case .Agent:
        run_agent(sub_args)
    case .Gateway:
        run_gateway(sub_args)
    case .Channel:
        run_channel(sub_args)
    case .Cron:
        run_cron(sub_args)
    case .Help:
        print_usage()
    case .None:
        fmt.printf("Unknown command: %s\n\n", args[1])
        print_usage()
        os.exit(1)
    }
}

@test
test_example :: proc(t: ^testing.T) {
    testing.expect(t, true, "This test should pass")
}
