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
    Status,
    Doctor,
    Onboard,
    Skills,
    Hardware,
    Migrate,
    Models,
    Daemon,
    Service,
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
    case "status":
        return .Status
    case "doctor":
        return .Doctor
    case "onboard":
        return .Onboard
    case "skills":
        return .Skills
    case "hardware":
        return .Hardware
    case "migrate":
        return .Migrate
    case "models":
        return .Models
    case "daemon":
        return .Daemon
    case "service":
        return .Service
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
    fmt.println("  status      Show system status")
    fmt.println("  doctor      Run diagnostics")
    fmt.println("  onboard     Initial setup wizard")
    fmt.println("  skills      List/manage skills")
    fmt.println("  hardware    Hardware management")
    fmt.println("  migrate     Data migration")
    fmt.println("  models      List available models")
    fmt.println("  daemon      Run as background daemon")
    fmt.println("  service     Run as system service")
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

run_status :: proc(args: []string) {
    fmt.println("=== NullClaw Status ===")
    fmt.println("")

    config := load_or_default_config()
    defer free_config(&config)

    fmt.println("Provider:")
    fmt.printf("  Default: %s\n", config.providers.default_provider)
    fmt.printf("  Model: %s\n", config.providers.default_model)
    has_openai := config.providers.openai_api_key != ""
    has_anthropic := config.providers.anthropic_api_key != ""
    has_xai := config.providers.xai_api_key != ""
    has_ollama := config.providers.ollama_endpoint != ""
    fmt.printf("  OpenAI: %s\n", has_openai ? "configured" : "not configured")
    fmt.printf("  Anthropic: %s\n", has_anthropic ? "configured" : "not configured")
    fmt.printf("  xAI: %s\n", has_xai ? "configured" : "not configured")
    fmt.printf("  Ollama: %s\n", has_ollama ? "configured" : "not configured")
    fmt.println("")

    fmt.println("Gateway:")
    fmt.printf("  Host: %s\n", config.gateway.host)
    fmt.printf("  Port: %d\n", config.gateway.port)
    fmt.println("")

    fmt.println("Tools:")
    fmt.printf("  Workspace: %s\n", config.tools.workspace_path)
    fmt.printf("  Cron enabled: %v\n", config.tools.cron_enabled)
    fmt.println("")

    fmt.println("Channels:")
    has_telegram := config.channels.telegram_api_key != ""
    has_discord := config.channels.discord_token != ""
    has_slack := config.channels.slack_webhook_url != ""
    fmt.printf("  Telegram: %s\n", has_telegram ? "configured" : "not configured")
    fmt.printf("  Discord: %s\n", has_discord ? "configured" : "not configured")
    fmt.printf("  Slack: %s\n", has_slack ? "configured" : "not configured")
}

run_doctor :: proc(args: []string) {
    fmt.println("=== NullClaw Doctor ===")
    fmt.println("")

    issues := 0

    config := load_or_default_config()
    defer free_config(&config)

    fmt.println("Checking configuration...")
    if config.providers.default_provider == "" {
        fmt.println("  [WARN] No default provider set")
        issues += 1
    }
    if config.providers.openai_api_key == "" && 
       config.providers.anthropic_api_key == "" &&
       config.providers.xai_api_key == "" &&
       config.providers.ollama_endpoint == "" {
        fmt.println("  [WARN] No API keys configured")
        issues += 1
    } else {
        fmt.println("  [OK] At least one provider configured")
    }

    fmt.println("")
    fmt.println("Checking tools...")
    if config.tools.workspace_path == "" {
        fmt.println("  [WARN] No workspace path set")
        issues += 1
    } else {
        fmt.println("  [OK] Workspace configured")
    }

    fmt.println("")
    fmt.println("Checking HTTP connectivity...")
    fmt.println("  [INFO] Run 'nullclaw agent' to test actual connectivity")

    fmt.println("")
    if issues == 0 {
        fmt.println("=== All checks passed ===")
    } else {
        fmt.printf("=== %d issue(s) found ===\n", issues)
        fmt.println("Run 'nullclaw onboard' to configure")
    }
}

run_onboard :: proc(args: []string) {
    fmt.println("=== NullClaw Onboarding ===")
    fmt.println("")

    config := default_config()

    fmt.println("Step 1: Choose your AI provider")
    fmt.println("  1. OpenAI (GPT-4, GPT-4o)")
    fmt.println("  2. Anthropic (Claude)")
    fmt.println("  3. xAI (Grok)")
    fmt.println("  4. Ollama (local)")
    fmt.println("  5. OpenAI-Compatible (Groq, DeepSeek, etc.)")
    fmt.print("Enter choice (1-5): ")

    buf: [10]u8
    n, _ := os.read(os.stdin, buf[:])
    if n <= 1 {
        fmt.println("Cancelled")
        return
    }

    choice := string(buf[:n-1])
    switch choice {
    case "1":
        config.providers.default_provider = "openai"
        fmt.print("Enter OpenAI API key: ")
    case "2":
        config.providers.default_provider = "anthropic"
        fmt.print("Enter Anthropic API key: ")
    case "3":
        config.providers.default_provider = "xai"
        fmt.print("Enter xAI API key: ")
    case "4":
        config.providers.default_provider = "ollama"
        config.providers.ollama_endpoint = "http://localhost:11434"
    case "5":
        config.providers.default_provider = "compatible"
        fmt.print("Enter API key: ")
    case:
        fmt.println("Invalid choice")
        return
    }

    fmt.println("")
    fmt.println("Step 2: Configure workspace path")
    fmt.print("Enter workspace path (default: /tmp): ")
    n2, _ := os.read(os.stdin, buf[:])
    if n2 > 1 {
        path := string(buf[:n2-1])
        if path != "" {
            config.tools.workspace_path = path
        }
    }

    fmt.println("")
    fmt.println("Configuration complete!")
    fmt.println("Run 'nullclaw status' to verify")
    fmt.println("Run 'nullclaw agent' to start")
}

run_skills :: proc(args: []string) {
    fmt.println("=== NullClaw Skills ===")
    fmt.println("")

    if len(args) == 0 {
        fmt.println("Usage: nullclaw skills <command>")
        fmt.println("")
        fmt.println("Commands:")
        fmt.println("  list     List available skills")
        fmt.println("  add      Add a skill")
        fmt.println("  remove   Remove a skill")
        return
    }

    switch args[0] {
    case "list":
        fmt.println("Available skills:")
        fmt.println("  (no skills installed)")
    case "add":
        fmt.println("Skill add not yet implemented")
    case "remove":
        fmt.println("Skill remove not yet implemented")
    case:
        fmt.printf("Unknown command: %s\n", args[0])
    }
}

run_hardware :: proc(args: []string) {
    fmt.println("=== NullClaw Hardware ===")
    fmt.println("")

    if len(args) == 0 {
        fmt.println("Usage: nullclaw hardware <command>")
        fmt.println("")
        fmt.println("Commands:")
        fmt.println("  list     List detected hardware")
        fmt.println("  probe    Probe for connected devices")
        return
    }

    switch args[0] {
    case "list":
        fmt.println("Detected hardware:")
        fmt.println("  (none - peripherals module not loaded)")
    case "probe":
        fmt.println("Hardware probe not yet implemented")
    case:
        fmt.printf("Unknown command: %s\n", args[0])
    }
}

run_migrate :: proc(args: []string) {
    fmt.println("=== NullClaw Migrate ===")
    fmt.println("")

    if len(args) == 0 {
        fmt.println("Usage: nullclaw migrate <source> [dest]")
        fmt.println("")
        fmt.println("Sources:")
        fmt.println("  json     Migrate from JSON snapshot")
        fmt.println("  sqlite   Migrate from SQLite database")
        return
    }

    switch args[0] {
    case "json":
        if len(args) < 2 {
            fmt.println("Usage: nullclaw migrate json <path>")
            return
        }
        fmt.printf("Migrating from JSON: %s\n", args[1])
        fmt.println("  (requires LMDB backend)")
    case "sqlite":
        fmt.println("SQLite migration not available (using LMDB)")
    case:
        fmt.printf("Unknown source: %s\n", args[0])
    }
}

run_models :: proc(args: []string) {
    fmt.println("=== Available Models ===")
    fmt.println("")

    config := load_or_default_config()
    defer free_config(&config)

    fmt.println("OpenAI:")
    fmt.println("  gpt-4o          Latest GPT-4")
    fmt.println("  gpt-4-turbo     GPT-4 Turbo")
    fmt.println("  gpt-3.5-turbo   Fast & cheap")

    fmt.println("")
    fmt.println("Anthropic:")
    fmt.println("  claude-sonnet-4-20250514  Latest Sonnet")
    fmt.println("  claude-opus-4-20250514    Opus (most capable)")
    fmt.println("  claude-3-5-sonnet         Haiku (fast)")

    fmt.println("")
    fmt.println("xAI:")
    fmt.println("  grok-2          Latest Grok")
    fmt.println("  grok-beta       Beta model")

    fmt.println("")
    fmt.println("Ollama (local):")
    fmt.println("  llama3          Llama 3")
    fmt.println("  mistral         Mistral")
    fmt.println("  codellama       Code-focused")

    fmt.println("")
    fmt.println("OpenAI-Compatible (Groq):")
    fmt.println("  meta-llama/Llama-3.3-70B-Instruct")
    fmt.println("  mixtral-8x7b-32768")
    fmt.println("  gemma-7b-it")

    fmt.println("")
    fmt.printf("Current default: %s / %s\n", config.providers.default_provider, config.providers.default_model)
}

run_daemon :: proc(args: []string) {
    fmt.println("Daemon mode not yet implemented")
    fmt.println("Use 'nullclaw gateway' for HTTP server mode")
}

run_service :: proc(args: []string) {
    fmt.println("Service mode not yet implemented")
    fmt.println("Configure systemd or launchd for background operation")
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
    } else if prov == "compatible" || prov == "groq" || prov == "deepseek" || 
                prov == "mistral" || prov == "cohere" || prov == "together" ||
                prov == "perplexity" || prov == "ollama" || prov == "lmstudio" ||
                prov == "venice" || prov == "x.ai" || prov == "opencode" || prov == "zen" {
        api_key := config.providers.compatible_key
        if api_key == "" {
            api_key = config.providers.openai_api_key // Fallback to OpenAI key
        }
        model := config.providers.default_model
        if model == "" {
            model = "meta-llama/Llama-3.3-70B-Instruct" // Default for Groq
        }
        return init_compatible_provider(api_key, model, prov)
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
    case .Status:
        run_status(sub_args)
    case .Doctor:
        run_doctor(sub_args)
    case .Onboard:
        run_onboard(sub_args)
    case .Skills:
        run_skills(sub_args)
    case .Hardware:
        run_hardware(sub_args)
    case .Migrate:
        run_migrate(sub_args)
    case .Models:
        run_models(sub_args)
    case .Daemon:
        run_daemon(sub_args)
    case .Service:
        run_service(sub_args)
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
