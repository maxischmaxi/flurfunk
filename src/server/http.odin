package main

// Minimal outbound HTTP client on top of the system libcurl — just enough
// for the OAuth code exchange and userinfo requests. One easy handle per
// request; safe to call from any thread (curl_global_init runs in main).

import "base:runtime"
import "core:mem"
import "core:strings"

foreign import libcurl "system:curl"

@(private = "file")
Curl :: distinct rawptr

@(private = "file")
Curl_Slist :: struct {
	data: cstring,
	next: ^Curl_Slist,
}

// Option/info ids from curl.h (stable ABI).
@(private = "file") CURLOPT_WRITEDATA :: i32(10001)
@(private = "file") CURLOPT_URL :: i32(10002)
@(private = "file") CURLOPT_POSTFIELDS :: i32(10015)
@(private = "file") CURLOPT_USERAGENT :: i32(10018)
@(private = "file") CURLOPT_HTTPHEADER :: i32(10023)
@(private = "file") CURLOPT_WRITEFUNCTION :: i32(20011)
@(private = "file") CURLOPT_TIMEOUT :: i32(13)
@(private = "file") CURLOPT_FOLLOWLOCATION :: i32(52)
@(private = "file") CURLOPT_MAXREDIRS :: i32(68)
@(private = "file") CURLOPT_CONNECTTIMEOUT :: i32(78)
@(private = "file") CURLOPT_NOSIGNAL :: i32(99)
@(private = "file") CURLOPT_PROTOCOLS :: i32(181)
@(private = "file") CURLOPT_REDIR_PROTOCOLS :: i32(182)
@(private = "file") CURLINFO_RESPONSE_CODE :: i32(2097154)
@(private = "file") CURLPROTO_HTTP_HTTPS :: i64(1 | 2)
@(private = "file") CURL_GLOBAL_DEFAULT :: i64(3)

@(default_calling_convention = "c")
foreign libcurl {
	curl_global_init :: proc(flags: i64) -> i32 ---
	curl_easy_init :: proc() -> Curl ---
	curl_easy_cleanup :: proc(h: Curl) ---
	curl_easy_perform :: proc(h: Curl) -> i32 ---
	curl_easy_setopt :: proc(h: Curl, option: i32, #c_vararg args: ..any) -> i32 ---
	curl_easy_getinfo :: proc(h: Curl, info: i32, #c_vararg args: ..any) -> i32 ---
	curl_easy_escape :: proc(h: Curl, s: cstring, length: i32) -> cstring ---
	curl_free :: proc(p: rawptr) ---
	curl_slist_append :: proc(l: ^Curl_Slist, s: cstring) -> ^Curl_Slist ---
	curl_slist_free_all :: proc(l: ^Curl_Slist) ---
}

http_init :: proc() {
	_ = curl_global_init(CURL_GLOBAL_DEFAULT)
}

// Response bodies larger than this abort the transfer (hostile endpoint).
@(private = "file")
HTTP_MAX_BODY :: 1 * 1024 * 1024

@(private = "file")
Http_Sink :: struct {
	ctx:  runtime.Context,
	data: [dynamic]byte,
}

@(private = "file")
http_write_cb :: proc "c" (ptr: rawptr, size, nmemb: uint, ud: rawptr) -> uint {
	sink := (^Http_Sink)(ud)
	context = sink.ctx
	n := int(size * nmemb)
	if len(sink.data) + n > HTTP_MAX_BODY {
		return 0 // abort
	}
	if n > 0 {
		old := len(sink.data)
		resize(&sink.data, old + n)
		mem.copy(&sink.data[old], ptr, n)
	}
	return uint(n)
}

// Performs a GET (form == "") or form POST. Returns the HTTP status and the
// body (allocated with the given allocator). ok covers transport errors only —
// callers still have to check `status`.
http_request :: proc(url: string, form: string, headers: []string, allocator := context.allocator) -> (status: int, body: []byte, ok: bool) {
	h := curl_easy_init()
	if h == nil {
		return
	}
	defer curl_easy_cleanup(h)

	sink := Http_Sink{ctx = context}
	sink.data.allocator = allocator
	defer if !ok {
		delete(sink.data)
	}

	curl_url := strings.clone_to_cstring(url, context.temp_allocator)
	_ = curl_easy_setopt(h, CURLOPT_URL, curl_url)
	_ = curl_easy_setopt(h, CURLOPT_NOSIGNAL, i64(1))
	_ = curl_easy_setopt(h, CURLOPT_TIMEOUT, i64(15))
	_ = curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, i64(10))
	_ = curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, i64(1))
	_ = curl_easy_setopt(h, CURLOPT_MAXREDIRS, i64(5))
	_ = curl_easy_setopt(h, CURLOPT_PROTOCOLS, CURLPROTO_HTTP_HTTPS)
	_ = curl_easy_setopt(h, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP_HTTPS)
	_ = curl_easy_setopt(h, CURLOPT_USERAGENT, cstring("flurfunk-server"))
	_ = curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, http_write_cb)
	_ = curl_easy_setopt(h, CURLOPT_WRITEDATA, &sink)

	if form != "" {
		// POSTFIELDS is not copied — the temp cstring outlives the perform.
		_ = curl_easy_setopt(h, CURLOPT_POSTFIELDS, strings.clone_to_cstring(form, context.temp_allocator))
	}

	list: ^Curl_Slist
	for hd in headers {
		list = curl_slist_append(list, strings.clone_to_cstring(hd, context.temp_allocator))
	}
	if list != nil {
		_ = curl_easy_setopt(h, CURLOPT_HTTPHEADER, list)
	}
	defer curl_slist_free_all(list)

	if curl_easy_perform(h) != 0 {
		return
	}
	code: i64
	_ = curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code)
	return int(code), sink.data[:], true
}

// Percent-encodes one query parameter value (temp-allocated).
url_encode :: proc(s: string) -> string {
	h := curl_easy_init()
	if h == nil {
		return s
	}
	defer curl_easy_cleanup(h)
	raw := strings.clone_to_cstring(s, context.temp_allocator)
	esc := curl_easy_escape(h, raw, i32(len(s)))
	if esc == nil {
		return s
	}
	defer curl_free(rawptr(esc))
	return strings.clone(string(esc), context.temp_allocator)
}
