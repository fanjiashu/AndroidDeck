/* SPDX-License-Identifier: GPL-3.0-only */
#include <stddef.h>
#include <stdint.h>

typedef struct DeckRPC DeckRPC;
DeckRPC *deck_rpc_create(int port, const char *token, const uint8_t *request, size_t length);
int deck_rpc_perform(DeckRPC *client);
const uint8_t *deck_rpc_body(DeckRPC *client, size_t *length);
const char *deck_rpc_error(DeckRPC *client);
void deck_rpc_cancel(DeckRPC *client);
void deck_rpc_destroy(DeckRPC *client);
