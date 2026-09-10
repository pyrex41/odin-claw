package main

import "core:strings"
import "core:os"

foreign import libc "system:c"

foreign libc {
	fork    :: proc "c" () -> i32 ---
	execvp  :: proc "c" (file: cstring, argv: [^]cstring) -> i32 ---
	pipe    :: proc "c" (pipefd: ^[2]i32) -> i32 ---
	dup2    :: proc "c" (oldfd: i32, newfd: i32) -> i32 ---
	close   :: proc "c" (fd: i32) -> i32 ---
	read    :: proc "c" (fd: i32, buf: rawptr, count: uint) -> int ---
	write   :: proc "c" (fd: i32, buf: rawptr, count: uint) -> int ---
	waitpid :: proc "c" (pid: i32, status: ^i32, options: i32) -> i32 ---
	kill    :: proc "c" (pid: i32, sig: i32) -> i32 ---
}

STDIN_FILENO  :: 0
STDOUT_FILENO :: 1
STDERR_FILENO :: 2
SIGTERM :: 15
WNOHANG :: 1

SubProcess :: struct {
	pid:       i32,
	stdin_fd:  i32,
	stdout_fd: i32,
	running:   bool,
}

spawn_process :: proc(command: string, args: []string) -> (^SubProcess, bool) {
	stdin_pipe: [2]i32
	stdout_pipe: [2]i32

	if pipe(&stdin_pipe) != 0 {
		return nil, false
	}
	if pipe(&stdout_pipe) != 0 {
		close(stdin_pipe[0])
		close(stdin_pipe[1])
		return nil, false
	}

	pid := fork()
	if pid < 0 {
		close(stdin_pipe[0])
		close(stdin_pipe[1])
		close(stdout_pipe[0])
		close(stdout_pipe[1])
		return nil, false
	}

	if pid == 0 {
		close(stdin_pipe[1])
		close(stdout_pipe[0])

		dup2(stdin_pipe[0], STDIN_FILENO)
		dup2(stdout_pipe[1], STDOUT_FILENO)
		dup2(stdout_pipe[1], STDERR_FILENO)

		close(stdin_pipe[0])
		close(stdout_pipe[1])

		cmd_c := strings.clone_to_cstring(command)
		argv := make([]cstring, len(args) + 2)
		argv[0] = cmd_c
		for i := 0; i < len(args); i += 1 {
			argv[i + 1] = strings.clone_to_cstring(args[i])
		}
		argv[len(args) + 1] = nil

		execvp(cmd_c, &argv[0])
		os.exit(1)
	}

	close(stdin_pipe[0])
	close(stdout_pipe[1])

	sp := new(SubProcess)
	sp.pid = pid
	sp.stdin_fd = stdin_pipe[1]
	sp.stdout_fd = stdout_pipe[0]
	sp.running = true

	return sp, true
}

subprocess_write :: proc(sp: ^SubProcess, data: string) -> bool {
	if sp == nil || !sp.running {
		return false
	}
	n := write(sp.stdin_fd, raw_data(data), uint(len(data)))
	return n == len(data)
}

subprocess_read_line :: proc(sp: ^SubProcess) -> (string, bool) {
	if sp == nil || !sp.running {
		return "", false
	}

	buf := make([]u8, 4096)
	n := read(sp.stdout_fd, raw_data(buf), 4095)
	if n <= 0 {
		return "", false
	}

	for i := 0; i < n; i += 1 {
		if buf[i] == '\n' {
			return string(buf[:i]), true
		}
	}
	return string(buf[:n]), n > 0
}

subprocess_kill :: proc(sp: ^SubProcess) {
	if sp == nil || !sp.running {
		return
	}
	kill(sp.pid, SIGTERM)
}

subprocess_is_alive :: proc(sp: ^SubProcess) -> bool {
	if sp == nil || !sp.running {
		return false
	}
	status: i32
	result := waitpid(sp.pid, &status, WNOHANG)
	if result == 0 {
		return true
	}
	sp.running = false
	return false
}

deinit_subprocess :: proc(sp: ^SubProcess) {
	if sp == nil {
		return
	}
	if sp.running {
		subprocess_kill(sp)
		status: i32
		waitpid(sp.pid, &status, 0)
	}
	if sp.stdin_fd >= 0 {
		close(sp.stdin_fd)
	}
	if sp.stdout_fd >= 0 {
		close(sp.stdout_fd)
	}
	free(sp)
}
