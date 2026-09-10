package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:thread"

foreign import libc "system:c"

foreign libc {
	@(link_name="getpid")
	_getpid :: proc "c" () -> i32 ---
}

// DaemonConfig holds paths and working directory for daemon operation
DaemonConfig :: struct {
	pid_file: string,
	log_file: string,
	work_dir: string,
}

// Daemon tracks daemon lifecycle state
Daemon :: struct {
	config:          DaemonConfig,
	running:         bool,
	gateway_started: bool,
	cron_started:    bool,
}

GatewayThreadCtx :: struct {
	config:   ^Config,
	host:     string,
	port:     int,
	provider: Provider,
	tools:    []Tool,
	mem:      Memory,
}

gateway_thread_proc :: proc(t: ^thread.Thread) {
	ctx := (^GatewayThreadCtx)(t.data)
	start_gateway(ctx.config, ctx.host, ctx.port, ctx.provider, ctx.tools, ctx.mem)
}

// init_daemon allocates and initializes a Daemon from the given config
init_daemon :: proc(config: DaemonConfig) -> ^Daemon {
	d := new(Daemon)
	d.config = config
	d.running = false
	d.gateway_started = false
	d.cron_started = false
	return d
}

// deinit_daemon cleans up and frees the Daemon
deinit_daemon :: proc(d: ^Daemon) {
	if d == nil {
		return
	}
	if d.running {
		stop_daemon(d)
	}
	free(d)
}

// write_pid_file writes the current process PID to the configured pid_file
write_pid_file :: proc(d: ^Daemon) -> bool {
	pid := int(_getpid())
	pid_str := fmt.tprintf("%d\n", pid)
	ok := os.write_entire_file(d.config.pid_file, transmute([]u8)pid_str)
	if !ok {
		fmt.printf("[daemon] Failed to write PID file: %s\n", d.config.pid_file)
		return false
	}
	fmt.printf("[daemon] Wrote PID %d to %s\n", pid, d.config.pid_file)
	return true
}

// remove_pid_file removes the PID file from disk
remove_pid_file :: proc(d: ^Daemon) {
	err := os.remove(d.config.pid_file)
	if err != nil {
		fmt.printf("[daemon] Warning: could not remove PID file %s\n", d.config.pid_file)
	} else {
		fmt.printf("[daemon] Removed PID file %s\n", d.config.pid_file)
	}
}

// read_pid_file reads a PID from the given file path, returns (pid, ok)
read_pid_file :: proc(path: string) -> (int, bool) {
	data, ok := os.read_entire_file(path)
	if !ok {
		return 0, false
	}
	defer delete(data)

	content := strings.trim_space(string(data))
	if content == "" {
		return 0, false
	}

	pid, parse_ok := strconv.parse_int(content)
	if !parse_ok {
		return 0, false
	}
	return pid, true
}

// is_daemon_running checks whether a daemon is already running by reading the
// PID file and verifying the process exists
is_daemon_running :: proc(pid_file: string) -> bool {
	pid, ok := read_pid_file(pid_file)
	if !ok {
		return false
	}

	if pid <= 0 {
		return false
	}

	// Check /proc/<pid> on Linux; on macOS this path won't exist so we
	// fall back to assuming the process is alive if the PID file is valid.
	proc_path := fmt.tprintf("/proc/%d", pid)
	if os.exists(proc_path) {
		return true
	}

	// On macOS /proc doesn't exist -- treat a valid PID file as running
	return true
}

// start_daemon marks the daemon as running, writes the PID file, and logs startup
start_daemon :: proc(d: ^Daemon) {
	d.running = true
	write_pid_file(d)

	pid := int(_getpid())
	fmt.printf("[daemon] Started (PID %d)\n", pid)
	fmt.printf("[daemon] Log file: %s\n", d.config.log_file)
	fmt.printf("[daemon] Work dir: %s\n", d.config.work_dir)
}

// stop_daemon marks the daemon as stopped, removes the PID file, and logs shutdown
stop_daemon :: proc(d: ^Daemon) {
	fmt.printf("[daemon] Shutting down...\n")
	d.running = false
	d.gateway_started = false
	d.cron_started = false
	remove_pid_file(d)
	fmt.printf("[daemon] Stopped\n")
}

// daemon_main_loop is the primary run loop. It logs a heartbeat every 60
// seconds and serves as the placeholder for gateway + cron tick integration.
daemon_main_loop :: proc(d: ^Daemon) {
	if !d.running {
		fmt.printf("[daemon] Cannot enter main loop: daemon not started\n")
		return
	}

	fmt.printf("[daemon] Entering main loop\n")

	config := load_or_default_config()
	defer free_config(&config)

	mem_path := config.memory.db_path
	if mem_path == "" { mem_path = "/tmp/odin-claw/memory" }
	mem, mem_ok := init_lmdb_memory(mem_path)
	if !mem_ok {
		mem = init_in_memory()
		fmt.println("[daemon] Using in-memory storage")
	} else {
		fmt.println("[daemon] Using LMDB storage")
	}
	defer {
		if mem_ok {
			deinit_lmdb_memory(mem)
		} else {
			deinit_in_memory(mem)
		}
	}

	tools := get_tools(mem)
	defer delete(tools)

	provider := create_provider_from_config(&config)
	defer provider.vtable.deinit(provider.ptr)

	gw_ctx := new(GatewayThreadCtx)
	gw_ctx.config = &config
	gw_ctx.host = config.gateway.host
	gw_ctx.port = config.gateway.port
	gw_ctx.provider = provider
	gw_ctx.tools = tools
	gw_ctx.mem = mem

	gw_thread := thread.create(gateway_thread_proc)
	gw_thread.data = gw_ctx
	thread.start(gw_thread)
	d.gateway_started = true
	fmt.printf("[daemon] Gateway started in thread on %s:%d\n", config.gateway.host, config.gateway.port)

	cs := init_cron_scheduler()
	defer deinit_cron_scheduler(cs)
	start_scheduler(cs)
	d.cron_started = true
	fmt.printf("[daemon] Cron scheduler started\n")

	tick: u64 = 0
	for d.running {
		tick += 1

		tick_scheduler(cs)

		if tick % 60 == 0 {
			fmt.printf("[daemon] Heartbeat tick=%d\n", tick)
		}

		time.sleep(1 * time.Second)
	}

	stop_scheduler(cs)
	thread.destroy(gw_thread)
	free(gw_ctx)

	fmt.printf("[daemon] Main loop exited\n")
}
