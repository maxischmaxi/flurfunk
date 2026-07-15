package shared

import "core:net"

// Low-level Framing: u16 (big endian) Länge + Payload.
// Wird für Noise-Handshake-Nachrichten und für einzelne versiegelte
// Chunks des Secure Channels benutzt.

FRAME_MAX :: 65535

send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	data := data
	for len(data) > 0 {
		n, err := net.send_tcp(sock, data)
		if err != nil || n <= 0 {
			return false
		}
		data = data[n:]
	}
	return true
}

recv_exact :: proc(sock: net.TCP_Socket, buf: []byte) -> bool {
	buf := buf
	for len(buf) > 0 {
		n, err := net.recv_tcp(sock, buf)
		if err != nil || n <= 0 {
			return false
		}
		buf = buf[n:]
	}
	return true
}

write_frame :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	if len(data) > FRAME_MAX {
		return false
	}
	hdr: [2]byte
	hdr[0] = byte(len(data) >> 8)
	hdr[1] = byte(len(data))
	if !send_all(sock, hdr[:]) {
		return false
	}
	return send_all(sock, data)
}

read_frame :: proc(sock: net.TCP_Socket, allocator := context.allocator) -> ([]byte, bool) {
	hdr: [2]byte
	if !recv_exact(sock, hdr[:]) {
		return nil, false
	}
	length := int(hdr[0]) << 8 | int(hdr[1])
	if length == 0 {
		return nil, true
	}
	buf := make([]byte, length, allocator)
	if !recv_exact(sock, buf) {
		delete(buf, allocator)
		return nil, false
	}
	return buf, true
}
