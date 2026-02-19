package main

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

// GatewayConfig holds configuration for the HTTP server subsystem
GatewayConfig :: struct {
    port: int,
    host: string,
    cors_origins: []string,
    rate_limit: int, // requests per minute
    pairing_timeout: int, // seconds
    health_check_path: string,
}

// AgentConfig holds configuration for the agent orchestration subsystem
AgentConfig :: struct {
    max_loop_iterations: int,
    compaction_threshold: int,
    recovery_attempts: int,
    subagent_limit: int,
    streaming_enabled: bool,
}

// PeripheralsConfig holds configuration for hardware interfaces
PeripheralsConfig :: struct {
    serial_devices: []string,
    gpio_pins: []int,
    firmware_path: string,
    probe_rs_path: string,
}

// SecurityConfig holds configuration for sandboxing and security enforcement
SecurityConfig :: struct {
    sandbox_backend: string,
    secret_key: string, // encrypted key
    audit_log_path: string,
    retention_days: int,
    cpu_limit: int, // percentage
    memory_limit: int, // MB
}

// RuntimeConfig holds configuration for execution environments
RuntimeConfig :: struct {
    runtime_type: string,
    memory_limit: int, // MB
    cpu_limit: int, // percentage
    disk_limit: int, // MB
    storage_path: string,
    allowed_paths: []string,
}

// ToolsConfig holds configuration for tool extensions
ToolsConfig :: struct {
    workspace_path: string,
    allowed_paths: []string,
    cron_enabled: bool,
    cron_schedule: string,
}

// MemoryConfig holds configuration for persistent storage
MemoryConfig :: struct {
    db_path: string,
    embedding_provider: string,
    api_key: string, // for embedding provider
    hygiene_interval: int, // seconds
    backend: string,
    snapshot_path: string,
}

// ChannelsConfig holds configuration for messaging platforms
ChannelsConfig :: struct {
    telegram_api_key: string,
    discord_token: string,
    slack_webhook_url: string,
    matrix_homeserver: string,
    whatsapp_api_key: string,
    allowlist: []string, // user IDs
    rate_limit: int,
}

// ProvidersConfig holds configuration for AI model providers
ProvidersConfig :: struct {
    openai_api_key: string,
    anthropic_api_key: string,
    xai_api_key: string,
    ollama_endpoint: string,
    gemini_key: string,
    default_provider: string,
    default_model: string,
    retry_attempts: int,
    streaming_enabled: bool,
}

// Config is the main configuration struct embedding all subsystem configs
Config :: struct {
    gateway: GatewayConfig,
    agent: AgentConfig,
    peripherals: PeripheralsConfig,
    security: SecurityConfig,
    runtime: RuntimeConfig,
    tools: ToolsConfig,
    memory: MemoryConfig,
    channels: ChannelsConfig,
    providers: ProvidersConfig,
}

// load_from_json loads configuration from a JSON file
load_from_json :: proc(path: string) -> (config: Config, ok: bool) {
    // Resolve ~ to home directory
    resolved_path := path
    if strings.has_prefix(path, "~") {
        home := os.get_env("HOME")
        if home != "" {
            resolved_path = strings.concatenate([]string{home, path[1:]})
        }
    }
    defer if resolved_path != path { delete(resolved_path) }

    data, read_ok := os.read_entire_file(resolved_path)
    if !read_ok {
        return {}, false
    }
    defer delete(data)

    err := json.unmarshal(data, &config)
    if err != nil {
        return {}, false
    }

    return config, true
}

// apply_env_overrides applies environment variable overrides to the config
apply_env_overrides :: proc(config: ^Config) {
    // Gateway overrides
    if port_str := os.get_env("NULLCLAW_GATEWAY_PORT"); port_str != "" {
        if port, ok := strconv.parse_int(port_str); ok {
            config.gateway.port = port
        }
    }
    if host := os.get_env("NULLCLAW_GATEWAY_HOST"); host != "" {
        config.gateway.host = host
    }
    // Add more overrides as needed for other fields
    // For simplicity, only showing a few; in full impl, add all

    // Security overrides (careful with secrets)
    if secret_key := os.get_env("NULLCLAW_SECURITY_SECRET_KEY"); secret_key != "" {
        config.security.secret_key = secret_key
    }

    // Providers
    if openai_key := os.get_env("NULLCLAW_PROVIDERS_OPENAI_API_KEY"); openai_key != "" {
        config.providers.openai_api_key = openai_key
    }
    // Add others similarly
}

// default_config returns a Config with default values
default_config :: proc() -> Config {
    return Config{
        gateway = {
            port = 8080,
            host = "localhost",
            cors_origins = {},
            rate_limit = 100,
            pairing_timeout = 300,
            health_check_path = "/health",
        },
        agent = {
            max_loop_iterations = 100,
            compaction_threshold = 1000,
            recovery_attempts = 3,
            subagent_limit = 10,
            streaming_enabled = true,
        },
        peripherals = {
            serial_devices = {},
            gpio_pins = {},
            firmware_path = "/usr/local/firmware",
            probe_rs_path = "/usr/local/bin/probe-rs",
        },
        security = {
            sandbox_backend = "landlock",
            secret_key = "",
            audit_log_path = "/var/log/nullclaw/audit.log",
            retention_days = 30,
            cpu_limit = 50,
            memory_limit = 512,
        },
        runtime = {
            runtime_type = "native",
            memory_limit = 512,
            cpu_limit = 50,
            disk_limit = 1024,
            storage_path = "/var/lib/nullclaw",
            allowed_paths = {},
        },
        tools = {
            workspace_path = "/tmp/nullclaw",
            allowed_paths = {},
            cron_enabled = false,
            cron_schedule = "",
        },
        memory = {
            db_path = "/var/lib/nullclaw/memory.db",
            embedding_provider = "openai",
            api_key = "",
            hygiene_interval = 3600,
            backend = "sqlite",
            snapshot_path = "/var/lib/nullclaw/snapshots",
        },
        channels = {
            telegram_api_key = "",
            discord_token = "",
            slack_webhook_url = "",
            matrix_homeserver = "",
            whatsapp_api_key = "",
            allowlist = {},
            rate_limit = 100,
        },
        providers = {
            openai_api_key = "",
            anthropic_api_key = "",
            xai_api_key = "",
            ollama_endpoint = "http://localhost:11434",
            gemini_key = "",
            default_provider = "openai",
            default_model = "gpt-4o",
            retry_attempts = 3,
            streaming_enabled = true,
        },
    }
}

// validate checks if the configuration is valid
validate :: proc(config: Config) -> bool {
    // Check gateway
    if config.gateway.port <= 0 || config.gateway.port > 65535 {
        return false
    }
    if config.gateway.host == "" {
        return false
    }
    if config.gateway.rate_limit < 0 {
        return false
    }

    // Check agent
    if config.agent.max_loop_iterations < 0 {
        return false
    }

    // Check security
    if config.security.sandbox_backend == "" {
        return false
    }
    if config.security.memory_limit < 0 {
        return false
    }

    // Check runtime
    if config.runtime.runtime_type != "native" && config.runtime.runtime_type != "docker" && config.runtime.runtime_type != "wasm" {
        return false
    }

    // Check memory
    if config.memory.db_path == "" {
        return false
    }

    // Add more validations as needed

    return true
}

@test
test_validate_valid_config :: proc(t: ^testing.T) {
    config := default_config()
    testing.expect(t, validate(config), "Default config should pass validation")
}

@test
test_validate_invalid_config :: proc(t: ^testing.T) {
    config := Config{} // all zero, invalid
    testing.expect(t, !validate(config), "Invalid config should fail validation")
}