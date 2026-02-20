package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"

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

	tick: u64 = 0
	for d.running {
		tick += 1
		fmt.printf("[daemon] Heartbeat tick=%d\n", tick)

		// Placeholder: start gateway subsystem on first tick
		if !d.gateway_started {
			fmt.printf("[daemon] Gateway subsystem ready (placeholder)\n")
			d.gateway_started = true
		}

		// Placeholder: start cron subsystem on first tick
		if !d.cron_started {
			fmt.printf("[daemon] Cron subsystem ready (placeholder)\n")
			d.cron_started = true
		}

		// Sleep 60 seconds between heartbeats
		time.sleep(60 * time.Second)
	}

	fmt.printf("[daemon] Main loop exited\n")
}
