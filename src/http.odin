package main

import "base:runtime"
import "core:strings"

CURL :: rawptr
CURLcode :: i32
curl_slist :: struct {
    data: cstring,
    next: ^curl_slist,
}

CURLE_OK : CURLcode : 0

CURLOPT_WRITEDATA      : i32 : 10001
CURLOPT_URL            : i32 : 10002
CURLOPT_POSTFIELDS     : i32 : 10015
CURLOPT_HTTPHEADER     : i32 : 10023
CURLOPT_WRITEFUNCTION  : i32 : 20011
CURLOPT_CUSTOMREQUEST  : i32 : 10036
CURLOPT_POSTFIELDSIZE  : i32 : 60
CURLOPT_TIMEOUT        : i32 : 13

CURLINFO_RESPONSE_CODE : i32 : 0x200002

HTTP_Error :: enum {
    None,
    Init_Failed,
    Request_Failed,
    Timeout,
}

HTTP_Response :: struct {
    body:        string,
    status_code: int,
}

Write_Context :: struct {
    sb:  ^strings.Builder,
    ctx: runtime.Context,
}

foreign import libcurl "system:curl"
foreign import curl_helpers "curl_helpers.o"

@(default_calling_convention = "c")
foreign libcurl {
    curl_easy_init    :: proc() -> CURL ---
    curl_easy_cleanup :: proc(curl: CURL) ---
    curl_easy_perform :: proc(curl: CURL) -> CURLcode ---
    curl_slist_append   :: proc(list: ^curl_slist, s: cstring) -> ^curl_slist ---
    curl_slist_free_all :: proc(list: ^curl_slist) ---
}

@(default_calling_convention = "c")
foreign curl_helpers {
    curl_setopt_ptr  :: proc(curl: CURL, option: i32, param: rawptr) -> CURLcode ---
    curl_setopt_long :: proc(curl: CURL, option: i32, param: i64) -> CURLcode ---
    curl_getinfo_long :: proc(curl: CURL, info: i32, out: ^i64) -> CURLcode ---
}

curl_write_callback :: proc "c" (ptr: [^]u8, size: uint, nmemb: uint, userdata: rawptr) -> uint {
    total := size * nmemb
    wctx := (^Write_Context)(userdata)
    data := ptr[:total]
    context = wctx.ctx
    strings.write_bytes(wctx.sb, data)
    return total
}

http_request :: proc(method: string, url: string, body: string, headers: []string) -> (HTTP_Response, HTTP_Error) {
    curl := curl_easy_init()
    if curl == nil {
        return {}, .Init_Failed
    }
    defer curl_easy_cleanup(curl)

    // Allocate all cstrings at function scope so they live until after perform
    c_url := strings.clone_to_cstring(url)
    defer delete(c_url)
    curl_setopt_ptr(curl, CURLOPT_URL, rawptr(c_url))

    c_method: cstring = nil
    if method != "GET" {
        c_method = strings.clone_to_cstring(method)
        curl_setopt_ptr(curl, CURLOPT_CUSTOMREQUEST, rawptr(c_method))
    }
    defer if c_method != nil { delete(c_method) }

    c_body: cstring = nil
    if body != "" {
        c_body = strings.clone_to_cstring(body)
        curl_setopt_ptr(curl, CURLOPT_POSTFIELDS, rawptr(c_body))
        curl_setopt_long(curl, CURLOPT_POSTFIELDSIZE, i64(len(body)))
    }
    defer if c_body != nil { delete(c_body) }

    // Build header list - slist copies strings internally
    header_list: ^curl_slist = nil
    for h in headers {
        c_h := strings.clone_to_cstring(h)
        header_list = curl_slist_append(header_list, c_h)
        delete(c_h) // slist_append copies the string
    }
    if header_list != nil {
        curl_setopt_ptr(curl, CURLOPT_HTTPHEADER, rawptr(header_list))
    }
    defer if header_list != nil { curl_slist_free_all(header_list) }

    curl_setopt_long(curl, CURLOPT_TIMEOUT, 30)

    sb := strings.builder_make()
    wctx := Write_Context{sb = &sb, ctx = context}
    curl_setopt_ptr(curl, CURLOPT_WRITEFUNCTION, rawptr(curl_write_callback))
    curl_setopt_ptr(curl, CURLOPT_WRITEDATA, &wctx)

    res := curl_easy_perform(curl)
    if res != CURLE_OK {
        strings.builder_destroy(&sb)
        return {}, .Request_Failed
    }

    status: i64
    curl_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &status)

    return HTTP_Response{
        body        = strings.to_string(sb),
        status_code = int(status),
    }, .None
}

http_get :: proc(url: string, headers: []string) -> (HTTP_Response, HTTP_Error) {
    return http_request("GET", url, "", headers)
}

http_post_request :: proc(url: string, body: string, headers: []string) -> (HTTP_Response, HTTP_Error) {
    return http_request("POST", url, body, headers)
}
