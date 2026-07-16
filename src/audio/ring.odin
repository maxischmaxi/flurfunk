package audio

// Lock-freier SPSC-Ringpuffer für f32-Samples — die Brücke zwischen dem
// Echtzeit-Audio-Callback (miniaudio) und dem Worker-Thread. Genau EIN
// Schreiber und EIN Leser; Kapazität ist eine Zweierpotenz.

import "core:sync"

Ring :: struct {
	buf:  []f32,
	mask: u64,
	r, w: u64, // monoton wachsende Positionen (nur via Atomics)
}

ring_init :: proc(rb: ^Ring, cap_pow2: int) {
	assert(cap_pow2 & (cap_pow2 - 1) == 0)
	rb.buf = make([]f32, cap_pow2)
	rb.mask = u64(cap_pow2 - 1)
	rb.r, rb.w = 0, 0
}

ring_destroy :: proc(rb: ^Ring) {
	delete(rb.buf)
	rb^ = {}
}

ring_fill :: proc(rb: ^Ring) -> int {
	w := sync.atomic_load_explicit(&rb.w, .Acquire)
	r := sync.atomic_load_explicit(&rb.r, .Acquire)
	return int(w - r)
}

// Schreibt so viele Samples wie Platz ist; Rückgabe = geschrieben.
ring_write :: proc(rb: ^Ring, samples: []f32) -> int {
	w := sync.atomic_load_explicit(&rb.w, .Relaxed)
	r := sync.atomic_load_explicit(&rb.r, .Acquire)
	space := len(rb.buf) - int(w - r)
	n := min(space, len(samples))
	for i in 0 ..< n {
		rb.buf[(w + u64(i)) & rb.mask] = samples[i]
	}
	sync.atomic_store_explicit(&rb.w, w + u64(n), .Release)
	return n
}

// Liest bis zu len(out) Samples; Rückgabe = gelesen (Rest bleibt unberührt).
ring_read :: proc(rb: ^Ring, out: []f32) -> int {
	r := sync.atomic_load_explicit(&rb.r, .Relaxed)
	w := sync.atomic_load_explicit(&rb.w, .Acquire)
	avail := int(w - r)
	n := min(avail, len(out))
	for i in 0 ..< n {
		out[i] = rb.buf[(r + u64(i)) & rb.mask]
	}
	sync.atomic_store_explicit(&rb.r, r + u64(n), .Release)
	return n
}
