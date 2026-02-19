// Thin wrappers around libcurl variadic functions for Odin FFI.
// ARM64 ABI treats variadic args differently (stack vs registers),
// so we need non-variadic C functions to call from Odin.

#include <curl/curl.h>

CURLcode curl_setopt_ptr(CURL *curl, CURLoption opt, void *val) {
    return curl_easy_setopt(curl, opt, val);
}

CURLcode curl_setopt_long(CURL *curl, CURLoption opt, long val) {
    return curl_easy_setopt(curl, opt, val);
}

CURLcode curl_getinfo_long(CURL *curl, CURLINFO info, long *val) {
    return curl_easy_getinfo(curl, info, val);
}
