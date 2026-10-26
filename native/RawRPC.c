/* SPDX-License-Identifier: GPL-3.0-only */
#include "RawRPC.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct DeckRPC {
    CURL *curl;
    struct curl_slist *headers;
    atomic_int cancelled;
    uint8_t body[32768];
    size_t length;
    int grpc_status;
    char error[CURL_ERROR_SIZE];
};
static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static void initialize_curl(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static size_t receive_body(char *data, size_t size, size_t count, void *context) {
    DeckRPC *client = context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t bytes = size * count;
    if (bytes > sizeof(client->body) - client->length) return 0;
    memcpy(client->body + client->length, data, bytes);
    client->length += bytes;
    return bytes;
}
static size_t receive_header(char *data, size_t size, size_t count, void *context) {
    DeckRPC *client = context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t bytes = size * count;
    if (bytes >= 12 && !strncasecmp(data, "grpc-status:", 12)) {
        char line[64];
        size_t length = bytes < sizeof(line) - 1 ? bytes : sizeof(line) - 1;
        memcpy(line, data, length); line[length] = 0;
        char *end = NULL;
        long value = strtol(line + 12, &end, 10);
        if (end != line + 12 && value >= 0 && value <= 16) client->grpc_status = (int)value;
    }
    return bytes;
}
static int progress(void *context, curl_off_t total, curl_off_t now, curl_off_t upload_total, curl_off_t upload_now) {
    (void)total; (void)now; (void)upload_total; (void)upload_now;
    return atomic_load(&((DeckRPC *)context)->cancelled);
}
DeckRPC *deck_rpc_create(int port, const char *token, const uint8_t *request, size_t length) {
    if (port < 1 || port > 65535 || !token || !request || length < 5 || length > 8192 || strlen(token) > 2048) return NULL;
    pthread_once(&curl_once, initialize_curl);
    DeckRPC *client = calloc(1, sizeof(*client));
    if (!client) return NULL;
    atomic_init(&client->cancelled, 0);
    client->curl = curl_easy_init();
    if (!client->curl) { free(client); return NULL; }
    char url[160], authorization[2100];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/android.emulation.control.EmulatorController/getScreenshot", port);
    snprintf(authorization, sizeof(authorization), "authorization: Bearer %s", token);
    const char *headers[] = {"Content-Type: application/grpc", "TE: trailers", authorization};
    for (size_t i = 0; i < 3; i++) {
        struct curl_slist *next = curl_slist_append(client->headers, headers[i]);
        if (!next) { deck_rpc_destroy(client); return NULL; }
        client->headers = next;
    }
#define OPTION(key, value) do { if (curl_easy_setopt(client->curl, key, value) != CURLE_OK) { deck_rpc_destroy(client); return NULL; } } while (0)
    OPTION(CURLOPT_URL, url);
    OPTION(CURLOPT_HTTPHEADER, client->headers);
    OPTION(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE);
    OPTION(CURLOPT_POST, 1L);
    OPTION(CURLOPT_POSTFIELDSIZE, (long)length);
    OPTION(CURLOPT_COPYPOSTFIELDS, request);
    OPTION(CURLOPT_WRITEFUNCTION, receive_body);
    OPTION(CURLOPT_WRITEDATA, client);
    OPTION(CURLOPT_HEADERFUNCTION, receive_header);
    OPTION(CURLOPT_HEADERDATA, client);
    OPTION(CURLOPT_ERRORBUFFER, client->error);
    OPTION(CURLOPT_CONNECTTIMEOUT_MS, 1500L);
    OPTION(CURLOPT_TIMEOUT_MS, 3000L);
    OPTION(CURLOPT_NOSIGNAL, 1L);
    OPTION(CURLOPT_NOPROXY, "*");
    OPTION(CURLOPT_NOPROGRESS, 0L);
    OPTION(CURLOPT_XFERINFOFUNCTION, progress);
    OPTION(CURLOPT_XFERINFODATA, client);
    return client;
}
int deck_rpc_perform(DeckRPC *client) {
    if (!client || atomic_load(&client->cancelled)) return -1;
    client->length = 0; client->grpc_status = -1; client->error[0] = 0;
    CURLcode result = curl_easy_perform(client->curl);
    if (result != CURLE_OK) {
        // Do not expose a request or authentication header in diagnostics.
        snprintf(client->error, sizeof(client->error), "本地画面请求失败（%d）", (int)result);
        return -1;
    }
    long status = 0;
    curl_easy_getinfo(client->curl, CURLINFO_RESPONSE_CODE, &status);
    if (status != 200 || client->grpc_status != 0) {
        snprintf(client->error, sizeof(client->error), "画面接口返回 HTTP %ld / gRPC %d", status, client->grpc_status);
        return -1;
    }
    return 0;
}
const uint8_t *deck_rpc_body(DeckRPC *client, size_t *length) {
    if (!client || !length) return NULL;
    *length = client->length; return client->body;
}
const char *deck_rpc_error(DeckRPC *client) { return client ? client->error : "本地画面客户端不可用"; }
void deck_rpc_cancel(DeckRPC *client) { if (client) atomic_store(&client->cancelled, 1); }
void deck_rpc_destroy(DeckRPC *client) {
    if (!client) return;
    // The owner must finish its serial worker before destroying the client.
    curl_easy_cleanup(client->curl);
    curl_slist_free_all(client->headers);
    free(client);
}
