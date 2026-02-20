package main

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// Tunnel Provider Types
// ============================================================================

Tunnel_Provider_Type :: enum {
	Cloudflare,
	Ngrok,
	Tailscale,
	Custom,
}

// ============================================================================
// Tunnel Configuration and State
// ============================================================================

Tunnel_Config :: struct {
	provider_type:  Tunnel_Provider_Type,
	auth_token:     string,
	subdomain:      string,
	local_port:     int,
	custom_command: string,
}

Tunnel :: struct {
	config:      Tunnel_Config,
	public_url:  string,
	running:     bool,
	process_cmd: string,
}

// ============================================================================
// Tunnel Lifecycle
// ============================================================================

// init_tunnel allocates and initializes a Tunnel from the given config
init_tunnel :: proc(config: Tunnel_Config) -> ^Tunnel {
	t := new(Tunnel)
	t.config = config
	t.public_url = ""
	t.running = false
	t.process_cmd = ""
	return t
}

// deinit_tunnel cleans up and frees the Tunnel
deinit_tunnel :: proc(t: ^Tunnel) {
	if t == nil {
		return
	}
	if t.process_cmd != "" {
		delete(t.process_cmd)
	}
	if t.public_url != "" {
		delete(t.public_url)
	}
	free(t)
}

// ============================================================================
// Command Building
// ============================================================================

// tunnel_build_command builds the CLI command string for the selected provider
tunnel_build_command :: proc(t: ^Tunnel) -> string {
	switch t.config.provider_type {
	case .Cloudflare:
		return fmt.aprintf(
			"cloudflared tunnel --url http://localhost:%d",
			t.config.local_port,
		)
	case .Ngrok:
		if t.config.subdomain != "" {
			return fmt.aprintf(
				"ngrok http %d --authtoken %s --subdomain %s",
				t.config.local_port,
				t.config.auth_token,
				t.config.subdomain,
			)
		}
		return fmt.aprintf(
			"ngrok http %d --authtoken %s",
			t.config.local_port,
			t.config.auth_token,
		)
	case .Tailscale:
		return fmt.aprintf(
			"tailscale funnel %d",
			t.config.local_port,
		)
	case .Custom:
		return strings.clone(t.config.custom_command)
	}
	return strings.clone("")
}

// ============================================================================
// Tunnel Control
// ============================================================================

// start_tunnel builds the command, logs it, and marks the tunnel as running.
// Actual subprocess execution is a placeholder for future implementation.
start_tunnel :: proc(t: ^Tunnel) -> bool {
	if t.running {
		fmt.printf("[Tunnel] Already running\n")
		return false
	}

	cmd := tunnel_build_command(t)
	if cmd == "" {
		fmt.printf("[Tunnel] Failed to build command for provider\n")
		return false
	}

	// Store the command on the tunnel
	if t.process_cmd != "" {
		delete(t.process_cmd)
	}
	t.process_cmd = cmd

	provider_name := tunnel_provider_name(t.config.provider_type)
	fmt.printf("[Tunnel] Starting %s tunnel on port %d\n", provider_name, t.config.local_port)
	fmt.printf("[Tunnel] Command: %s\n", t.process_cmd)

	// Placeholder: actual subprocess execution would happen here
	t.running = true

	// Set a placeholder public URL based on provider
	if t.public_url != "" {
		delete(t.public_url)
	}
	t.public_url = format_tunnel_url(t)

	fmt.printf("[Tunnel] Started successfully, public URL: %s\n", t.public_url)
	return true
}

// stop_tunnel marks the tunnel as stopped and logs shutdown
stop_tunnel :: proc(t: ^Tunnel) {
	if !t.running {
		fmt.printf("[Tunnel] Not running, nothing to stop\n")
		return
	}

	provider_name := tunnel_provider_name(t.config.provider_type)
	fmt.printf("[Tunnel] Stopping %s tunnel...\n", provider_name)

	// Placeholder: actual process termination would happen here
	t.running = false

	fmt.printf("[Tunnel] Stopped\n")
}

// ============================================================================
// Status and Reporting
// ============================================================================

// tunnel_status returns a formatted status string describing the tunnel state
tunnel_status :: proc(t: ^Tunnel) -> string {
	provider_name := tunnel_provider_name(t.config.provider_type)
	state := t.running ? "running" : "stopped"
	url := t.public_url if t.public_url != "" else "none"

	return fmt.aprintf(
		"[Tunnel] provider=%s state=%s port=%d url=%s",
		provider_name,
		state,
		t.config.local_port,
		url,
	)
}

// format_tunnel_url returns the public URL or a placeholder based on provider
format_tunnel_url :: proc(t: ^Tunnel) -> string {
	if t.public_url != "" && t.running {
		return strings.clone(t.public_url)
	}

	switch t.config.provider_type {
	case .Cloudflare:
		if t.config.subdomain != "" {
			return fmt.aprintf("https://%s.trycloudflare.com", t.config.subdomain)
		}
		return strings.clone("https://<random>.trycloudflare.com")
	case .Ngrok:
		if t.config.subdomain != "" {
			return fmt.aprintf("https://%s.ngrok.io", t.config.subdomain)
		}
		return strings.clone("https://<random>.ngrok.io")
	case .Tailscale:
		return fmt.aprintf("https://<hostname>:%d", t.config.local_port)
	case .Custom:
		return strings.clone("https://<custom-tunnel-url>")
	}
	return strings.clone("https://<unknown>")
}

// ============================================================================
// Provider Detection
// ============================================================================

// detect_tunnel_providers checks if common tunnel binaries are available in PATH.
// Uses os.exists on well-known binary paths as a placeholder heuristic.
detect_tunnel_providers :: proc() -> []Tunnel_Provider_Type {
	found := make([dynamic]Tunnel_Provider_Type)

	cloudflared_paths := []string{
		"/usr/local/bin/cloudflared",
		"/usr/bin/cloudflared",
		"/opt/homebrew/bin/cloudflared",
	}
	ngrok_paths := []string{
		"/usr/local/bin/ngrok",
		"/usr/bin/ngrok",
		"/opt/homebrew/bin/ngrok",
	}
	tailscale_paths := []string{
		"/usr/local/bin/tailscale",
		"/usr/bin/tailscale",
		"/opt/homebrew/bin/tailscale",
	}

	if check_binary_exists(cloudflared_paths) {
		append(&found, Tunnel_Provider_Type.Cloudflare)
		fmt.printf("[Tunnel] Detected provider: Cloudflare (cloudflared)\n")
	}
	if check_binary_exists(ngrok_paths) {
		append(&found, Tunnel_Provider_Type.Ngrok)
		fmt.printf("[Tunnel] Detected provider: Ngrok\n")
	}
	if check_binary_exists(tailscale_paths) {
		append(&found, Tunnel_Provider_Type.Tailscale)
		fmt.printf("[Tunnel] Detected provider: Tailscale\n")
	}

	if len(found) == 0 {
		fmt.printf("[Tunnel] No tunnel providers detected\n")
	} else {
		fmt.printf("[Tunnel] Detected %d tunnel provider(s)\n", len(found))
	}

	return found[:]
}

// ============================================================================
// Internal Helpers
// ============================================================================

// check_binary_exists returns true if any of the given paths exist on disk
check_binary_exists :: proc(paths: []string) -> bool {
	for path in paths {
		if os.exists(path) {
			return true
		}
	}
	return false
}

// tunnel_provider_name returns a human-readable name for a provider type
tunnel_provider_name :: proc(provider: Tunnel_Provider_Type) -> string {
	switch provider {
	case .Cloudflare:
		return "Cloudflare"
	case .Ngrok:
		return "Ngrok"
	case .Tailscale:
		return "Tailscale"
	case .Custom:
		return "Custom"
	}
	return "Unknown"
}
