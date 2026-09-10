package main

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:strings"

// WebSocket opcodes per RFC 6455 Section 5.2
WS_OPCODE_TEXT   :: 0x1
WS_OPCODE_BINARY :: 0x2
WS_OPCODE_CLOSE  :: 0x8
WS_OPCODE_PING   :: 0x9
WS_OPCODE_PONG   :: 0xA

// WebSocket_Frame represents a single decoded WebSocket frame
WebSocket_Frame :: struct {
	fin:      bool,
	opcode:   u8,
	masked:   bool,
	payload:  []byte,
	mask_key: [4]u8,
}

// WebSocket_Connection holds state for a WebSocket client connection
WebSocket_Connection :: struct {
	url:         string,
	connected:   bool,
	socket:      net.TCP_Socket,
	on_message:  proc(data: string),
	on_close:    proc(),
	send_buffer: [dynamic]u8,
	recv_buffer: [dynamic]u8,
}

// init_websocket allocates and initializes a WebSocket connection handle
init_websocket :: proc(url: string) -> ^WebSocket_Connection {
	ws := new(WebSocket_Connection)
	ws.url = url
	ws.connected = false
	ws.send_buffer = make([dynamic]u8)
	ws.recv_buffer = make([dynamic]u8)
	fmt.printf("[WebSocket] Initialized for %s\n", url)
	return ws
}

// deinit_websocket frees all resources owned by the connection
deinit_websocket :: proc(ws: ^WebSocket_Connection) {
	if ws == nil {
		return
	}
	delete(ws.send_buffer)
	delete(ws.recv_buffer)
	free(ws)
}

// ws_build_handshake constructs the HTTP/1.1 Upgrade request for the WebSocket handshake.
// Returns the complete request as a string ready to send over TCP.
ws_build_handshake :: proc(url: string, host: string) -> string {
	// Extract the path from the URL (everything after the host portion)
	path := "/"
	// Try to find path after the host in the URL
	after_scheme := url
	if strings.has_prefix(url, "ws://") {
		after_scheme = url[5:]
	} else if strings.has_prefix(url, "wss://") {
		after_scheme = url[6:]
	}
	slash_idx := strings.index(after_scheme, "/")
	if slash_idx >= 0 {
		path = after_scheme[slash_idx:]
	}

	// Placeholder base64-encoded 16-byte key (a real implementation would
	// generate 16 random bytes and base64-encode them)
	ws_key :: "dGhlIHNhbXBsZSBub25jZQ=="

	sb := strings.builder_make()
	strings.write_string(&sb, "GET ")
	strings.write_string(&sb, path)
	strings.write_string(&sb, " HTTP/1.1\r\n")
	strings.write_string(&sb, "Host: ")
	strings.write_string(&sb, host)
	strings.write_string(&sb, "\r\n")
	strings.write_string(&sb, "Upgrade: websocket\r\n")
	strings.write_string(&sb, "Connection: Upgrade\r\n")
	strings.write_string(&sb, "Sec-WebSocket-Key: ")
	strings.write_string(&sb, ws_key)
	strings.write_string(&sb, "\r\n")
	strings.write_string(&sb, "Sec-WebSocket-Version: 13\r\n")
	strings.write_string(&sb, "\r\n")

	return strings.to_string(sb)
}

// ws_encode_frame encodes a WebSocket frame per RFC 6455.
// Handles 7-bit, 16-bit, and 64-bit payload length encoding.
// If mask is true, generates a random 4-byte masking key and applies it.
ws_encode_frame :: proc(opcode: u8, payload: []byte, mask: bool) -> []byte {
	payload_len := len(payload)

	// Calculate total frame size
	header_size := 2 // first two bytes always present
	if payload_len <= 125 {
		// 7-bit length, fits in the second byte
	} else if payload_len <= 65535 {
		header_size += 2 // 16-bit extended length
	} else {
		header_size += 8 // 64-bit extended length
	}
	if mask {
		header_size += 4 // masking key
	}

	frame := make([]byte, header_size + payload_len)

	// Byte 0: FIN bit (1) + opcode
	frame[0] = 0x80 | (opcode & 0x0F)

	// Byte 1: MASK bit + payload length
	mask_bit: u8 = mask ? 0x80 : 0x00
	offset := 2

	if payload_len <= 125 {
		frame[1] = mask_bit | u8(payload_len)
	} else if payload_len <= 65535 {
		frame[1] = mask_bit | 126
		frame[2] = u8((payload_len >> 8) & 0xFF)
		frame[3] = u8(payload_len & 0xFF)
		offset = 4
	} else {
		frame[1] = mask_bit | 127
		pl := u64(payload_len)
		frame[2] = u8((pl >> 56) & 0xFF)
		frame[3] = u8((pl >> 48) & 0xFF)
		frame[4] = u8((pl >> 40) & 0xFF)
		frame[5] = u8((pl >> 32) & 0xFF)
		frame[6] = u8((pl >> 24) & 0xFF)
		frame[7] = u8((pl >> 16) & 0xFF)
		frame[8] = u8((pl >> 8) & 0xFF)
		frame[9] = u8(pl & 0xFF)
		offset = 10
	}

	if mask {
		// Generate random masking key
		mask_key: [4]u8
		for i in 0 ..< 4 {
			mask_key[i] = u8(rand.uint32() & 0xFF)
		}
		frame[offset] = mask_key[0]
		frame[offset + 1] = mask_key[1]
		frame[offset + 2] = mask_key[2]
		frame[offset + 3] = mask_key[3]
		offset += 4

		// Copy payload with masking applied
		for i in 0 ..< payload_len {
			frame[offset + i] = payload[i] ~ mask_key[i % 4]
		}
	} else {
		// Copy payload as-is
		for i in 0 ..< payload_len {
			frame[offset + i] = payload[i]
		}
	}

	return frame
}

// ws_decode_frame decodes a single WebSocket frame from raw bytes.
// Returns (frame, bytes_consumed, ok). If the data is incomplete, ok is false.
ws_decode_frame :: proc(data: []byte) -> (WebSocket_Frame, int, bool) {
	if len(data) < 2 {
		return {}, 0, false
	}

	frame: WebSocket_Frame
	offset := 2

	// Byte 0: FIN + opcode
	frame.fin = (data[0] & 0x80) != 0
	frame.opcode = data[0] & 0x0F

	// Byte 1: MASK + payload length
	frame.masked = (data[1] & 0x80) != 0
	length_field := u64(data[1] & 0x7F)
	payload_len: u64

	if length_field <= 125 {
		payload_len = length_field
	} else if length_field == 126 {
		// 16-bit extended length
		if len(data) < 4 {
			return {}, 0, false
		}
		payload_len = u64(data[2]) << 8 | u64(data[3])
		offset = 4
	} else {
		// 64-bit extended length
		if len(data) < 10 {
			return {}, 0, false
		}
		payload_len = u64(data[2]) << 56 |
			u64(data[3]) << 48 |
			u64(data[4]) << 40 |
			u64(data[5]) << 32 |
			u64(data[6]) << 24 |
			u64(data[7]) << 16 |
			u64(data[8]) << 8 |
			u64(data[9])
		offset = 10
	}

	// Read masking key if present
	if frame.masked {
		if len(data) < offset + 4 {
			return {}, 0, false
		}
		frame.mask_key[0] = data[offset]
		frame.mask_key[1] = data[offset + 1]
		frame.mask_key[2] = data[offset + 2]
		frame.mask_key[3] = data[offset + 3]
		offset += 4
	}

	// Ensure we have enough data for the full payload
	total_needed := offset + int(payload_len)
	if len(data) < total_needed {
		return {}, 0, false
	}

	// Extract and unmask payload
	frame.payload = make([]byte, int(payload_len))
	for i in 0 ..< int(payload_len) {
		if frame.masked {
			frame.payload[i] = data[offset + i] ~ frame.mask_key[i % 4]
		} else {
			frame.payload[i] = data[offset + i]
		}
	}

	return frame, total_needed, true
}

// ws_send_text encodes a masked text frame and sends it over the socket
ws_send_text :: proc(ws: ^WebSocket_Connection, text: string) {
	if !ws.connected {
		fmt.printf("[WebSocket] Cannot send: not connected\n")
		return
	}

	payload := transmute([]byte)text
	frame_data := ws_encode_frame(WS_OPCODE_TEXT, payload, true)
	defer delete(frame_data)

	net.send_tcp(ws.socket, frame_data)
}

// ws_send_close encodes a close frame and sends it over the socket
ws_send_close :: proc(ws: ^WebSocket_Connection) {
	if !ws.connected {
		return
	}

	empty: []byte
	frame_data := ws_encode_frame(WS_OPCODE_CLOSE, empty, true)
	defer delete(frame_data)

	net.send_tcp(ws.socket, frame_data)
}

// ws_send_ping encodes a ping frame and sends it over the socket
ws_send_ping :: proc(ws: ^WebSocket_Connection) {
	if !ws.connected {
		return
	}

	empty: []byte
	frame_data := ws_encode_frame(WS_OPCODE_PING, empty, true)
	defer delete(frame_data)

	net.send_tcp(ws.socket, frame_data)
}

// ws_connect performs TCP connect + HTTP upgrade handshake
ws_connect :: proc(ws: ^WebSocket_Connection) -> bool {
	fmt.printf("[WebSocket] Connecting to %s ...\n", ws.url)

	host := _extract_host(ws.url)
	port := _extract_port(ws.url)

	addr4 := net.IP4_Address{127, 0, 0, 1}
	endpoint := net.Endpoint{address = addr4, port = port}

	sock, err := net.dial_tcp(endpoint)
	if err != nil {
		fmt.printf("[WebSocket] TCP connect failed: %v\n", err)
		return false
	}

	handshake := ws_build_handshake(ws.url, host)
	net.send_tcp(sock, transmute([]u8)handshake)

	buf: [4096]u8
	n, recv_err := net.recv_tcp(sock, buf[:])
	if recv_err != nil || n <= 0 {
		fmt.printf("[WebSocket] Failed to receive handshake response\n")
		net.close(sock)
		return false
	}

	response := string(buf[:n])
	if !strings.contains(response, "101") {
		fmt.printf("[WebSocket] Handshake failed: %s\n", response[:min(100, len(response))])
		net.close(sock)
		return false
	}

	ws.socket = sock
	ws.connected = true
	fmt.printf("[WebSocket] Connected to %s\n", ws.url)
	return true
}

// ws_disconnect sends a close frame and marks the connection as disconnected
ws_disconnect :: proc(ws: ^WebSocket_Connection) {
	if !ws.connected {
		return
	}

	ws_send_close(ws)
	ws.connected = false
	net.close(ws.socket)

	if ws.on_close != nil {
		ws.on_close()
	}

	fmt.printf("[WebSocket] Disconnected from %s\n", ws.url)
}

ws_recv :: proc(ws: ^WebSocket_Connection) -> (string, bool) {
	if !ws.connected {
		return "", false
	}

	buf: [65536]u8
	n, err := net.recv_tcp(ws.socket, buf[:])
	if err != nil || n <= 0 {
		return "", false
	}

	frame, _, ok := ws_decode_frame(buf[:n])
	if !ok {
		return "", false
	}
	defer delete(frame.payload)

	if frame.opcode == WS_OPCODE_TEXT {
		return strings.clone(string(frame.payload)), true
	}
	if frame.opcode == WS_OPCODE_PING {
		pong := ws_encode_frame(WS_OPCODE_PONG, frame.payload, false)
		defer delete(pong)
		net.send_tcp(ws.socket, pong)
	}
	if frame.opcode == WS_OPCODE_CLOSE {
		ws.connected = false
		net.close(ws.socket)
	}
	return "", false
}

// _extract_host pulls the host portion from a ws:// or wss:// URL
_extract_host :: proc(url: string) -> string {
	after_scheme := url
	if strings.has_prefix(url, "ws://") {
		after_scheme = url[5:]
	} else if strings.has_prefix(url, "wss://") {
		after_scheme = url[6:]
	}

	// Host ends at the first '/' or end of string
	slash_idx := strings.index(after_scheme, "/")
	if slash_idx >= 0 {
		return after_scheme[:slash_idx]
	}
	return after_scheme
}

_extract_port :: proc(url: string) -> int {
	host_str := _extract_host(url)
	if colon := strings.last_index(host_str, ":"); colon >= 0 {
		return fast_atoi(host_str[colon+1:])
	}
	if strings.has_prefix(url, "wss://") { return 443 }
	return 80
}
