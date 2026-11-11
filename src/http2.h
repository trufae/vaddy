#ifndef VADDY_HTTP2_H
#define VADDY_HTTP2_H
#include <nghttp2/nghttp2.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define VADDY_H2_HEADERS 16384
#define VADDY_H2_INPUT 65535
#define VADDY_H2_OUTPUT 32768
#define VADDY_H2_STREAMS 64
#define VADDY_H2_WIRE 65536

struct vaddy_h2_stream {
    int id, ready, remote_end, closed, response_end, response_started;
    int header_count, header_len, header_bytes, input_len, output_len;
    uint32_t error;
    unsigned char *headers, *input, *output;
    struct vaddy_h2_stream *next;
};
struct vaddy_h2 {
    nghttp2_session *session;
    struct vaddy_h2_stream *streams;
    int stream_count, requests, max_requests, draining, wire_len;
    unsigned char wire[VADDY_H2_WIRE];
};

static struct vaddy_h2_stream *vaddy_h2_find(struct vaddy_h2 *h, int id) {
    for (struct vaddy_h2_stream *s = h->streams; s; s = s->next)
        if (s->id == id) return s;
    return NULL;
}
static int vaddy_h2_begin_headers(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    struct vaddy_h2 *h = user;
    if (frame->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
    if (h->draining || h->stream_count >= VADDY_H2_STREAMS || h->requests >= h->max_requests) {
        nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, frame->hd.stream_id, NGHTTP2_REFUSED_STREAM);
        return 0;
    }
    struct vaddy_h2_stream *s = calloc(1, sizeof *s);
    if (!s) return NGHTTP2_ERR_CALLBACK_FAILURE;
    s->headers = malloc(VADDY_H2_HEADERS);
    if (!s->headers) { free(s); return NGHTTP2_ERR_CALLBACK_FAILURE; }
    s->id = frame->hd.stream_id;
    s->next = h->streams; h->streams = s;
    h->stream_count++; h->requests++;
    nghttp2_session_set_stream_user_data(session, s->id, s);
    return 0;
}
static int vaddy_h2_header(nghttp2_session *session, const nghttp2_frame *frame,
                           const uint8_t *name, size_t namelen, const uint8_t *value,
                           size_t valuelen, uint8_t flags, void *user) {
    (void)flags; (void)user;
    struct vaddy_h2_stream *s = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    if (!s) return 0;
    // Trailer fields are validated by nghttp2 and counted against the same limit.
    if (++s->header_count > 128 || namelen + valuelen + 2 > VADDY_H2_HEADERS - (size_t)s->header_bytes) {
        nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, s->id, NGHTTP2_ENHANCE_YOUR_CALM);
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }
    s->header_bytes += (int)(namelen + valuelen + 2);
    if (frame->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
    memcpy(s->headers + s->header_len, name, namelen); s->header_len += (int)namelen;
    s->headers[s->header_len++] = 0;
    memcpy(s->headers + s->header_len, value, valuelen); s->header_len += (int)valuelen;
    s->headers[s->header_len++] = 0;
    return 0;
}
static int vaddy_h2_frame_recv(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    (void)user;
    struct vaddy_h2_stream *s = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    if (s) {
        if (frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST) s->ready = 1;
        if ((frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) &&
            (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) s->remote_end = 1;
    }
    return 0;
}
static int vaddy_h2_data(nghttp2_session *session, uint8_t flags, int32_t id,
                         const uint8_t *data, size_t length, void *user) {
    (void)flags; (void)user;
    struct vaddy_h2_stream *s = nghttp2_session_get_stream_user_data(session, id);
    if (!s || s->closed) { nghttp2_session_consume_connection(session, length); return 0; }
    if (length > VADDY_H2_INPUT - (size_t)s->input_len) return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (!s->input) { s->input = malloc(VADDY_H2_INPUT); if (!s->input) return NGHTTP2_ERR_CALLBACK_FAILURE; }
    memcpy(s->input + s->input_len, data, length); s->input_len += (int)length;
    return 0;
}
static int vaddy_h2_stream_close(nghttp2_session *session, int32_t id, uint32_t error, void *user) {
    (void)user;
    struct vaddy_h2_stream *s = nghttp2_session_get_stream_user_data(session, id);
    if (s) { s->closed = 1; s->error = error; }
    return 0;
}
static ssize_t vaddy_h2_send(nghttp2_session *session, const uint8_t *data, size_t length, int flags, void *user) {
    (void)session; (void)flags;
    struct vaddy_h2 *h = user;
    if (length > VADDY_H2_WIRE - (size_t)h->wire_len) return NGHTTP2_ERR_WOULDBLOCK;
    memcpy(h->wire + h->wire_len, data, length); h->wire_len += (int)length;
    return (ssize_t)length;
}
static ssize_t vaddy_h2_read_data(nghttp2_session *session, int32_t id, uint8_t *buffer,
                                  size_t length, uint32_t *flags, nghttp2_data_source *source, void *user) {
    (void)session; (void)id; (void)user;
    struct vaddy_h2_stream *s = source->ptr;
    if (!s->output_len && !s->response_end) return NGHTTP2_ERR_DEFERRED;
    size_t size = length < (size_t)s->output_len ? length : (size_t)s->output_len;
    if (size) {
        memcpy(buffer, s->output, size);
        memmove(s->output, s->output + size, s->output_len - size);
        s->output_len -= (int)size;
    }
    if (!s->output_len && s->response_end) *flags |= NGHTTP2_DATA_FLAG_EOF;
    return (ssize_t)size;
}
static int vaddy_h2_frame_sent(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    (void)user;
    struct vaddy_h2_stream *s = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    // Stop an unfinished upload only AFTER the final response has been serialized.
    if (s && !s->remote_end && (frame->hd.type == NGHTTP2_DATA || frame->hd.type == NGHTTP2_HEADERS) &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM))
        nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, s->id, NGHTTP2_NO_ERROR);
    return 0;
}
static void *vaddy_h2_new(int max_requests) {
    struct vaddy_h2 *h = calloc(1, sizeof *h);
    if (!h) return NULL;
    h->max_requests = max_requests;
    nghttp2_session_callbacks *callbacks = NULL;
    nghttp2_option *options = NULL;
    if (nghttp2_session_callbacks_new(&callbacks) || nghttp2_option_new(&options)) goto fail;
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, vaddy_h2_begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, vaddy_h2_header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, vaddy_h2_frame_recv);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, vaddy_h2_data);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, vaddy_h2_stream_close);
    nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, vaddy_h2_frame_sent);
    nghttp2_session_callbacks_set_send_callback(callbacks, vaddy_h2_send);
    nghttp2_option_set_no_auto_window_update(options, 1);
    nghttp2_option_set_max_outbound_ack(options, 100);
    nghttp2_option_set_max_send_header_block_length(options, VADDY_H2_HEADERS);
#if NGHTTP2_VERSION_NUM >= 0x013d00
    nghttp2_option_set_max_continuations(options, 8);
#endif
    if (nghttp2_session_server_new2(&h->session, callbacks, h, options)) goto fail;
    nghttp2_session_callbacks_del(callbacks); nghttp2_option_del(options);
    nghttp2_settings_entry settings[] = {
        {NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, VADDY_H2_STREAMS},
        {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, VADDY_H2_HEADERS}
    };
    if (nghttp2_submit_settings(h->session, NGHTTP2_FLAG_NONE, settings, 2)) {
        nghttp2_session_del(h->session); free(h); return NULL;
    }
    return h;
fail:
    nghttp2_session_callbacks_del(callbacks); nghttp2_option_del(options); free(h); return NULL;
}
static void vaddy_h2_free(void *pointer) {
    struct vaddy_h2 *h = pointer;
    if (!h) return;
    nghttp2_session_del(h->session);
    while (h->streams) {
        struct vaddy_h2_stream *s = h->streams; h->streams = s->next;
        free(s->headers); free(s->input); free(s->output); free(s);
    }
    free(h);
}
static int vaddy_h2_receive(void *pointer, const void *data, int length) {
    struct vaddy_h2 *h = pointer;
    ssize_t n = nghttp2_session_mem_recv(h->session, data, (size_t)length);
    return n < 0 ? -1 : (int)n;
}
static void vaddy_h2_drain(void *pointer);
static int vaddy_h2_flush(void *pointer) {
    struct vaddy_h2 *h = pointer;
    if (h->requests >= h->max_requests) vaddy_h2_drain(h);
    return nghttp2_session_send(h->session);
}
static int vaddy_h2_wire_len(void *pointer) { return ((struct vaddy_h2 *)pointer)->wire_len; }
static void *vaddy_h2_wire(void *pointer) { return ((struct vaddy_h2 *)pointer)->wire; }
static void vaddy_h2_wire_skip(void *pointer, int length) {
    struct vaddy_h2 *h = pointer;
    memmove(h->wire, h->wire + length, h->wire_len - length); h->wire_len -= length;
}
static struct vaddy_h2_stream *vaddy_h2_first(void *pointer) { return ((struct vaddy_h2 *)pointer)->streams; }
static int vaddy_h2_take(void *pointer, struct vaddy_h2_stream *s, void *buffer, int capacity) {
    struct vaddy_h2 *h = pointer;
    int length = capacity < s->input_len ? capacity : s->input_len;
    if (length) {
        memcpy(buffer, s->input, length); memmove(s->input, s->input + length, s->input_len - length);
        s->input_len -= length;
        if (nghttp2_session_consume(h->session, s->id, length)) return -1;
    }
    return length;
}
static int vaddy_h2_push(void *pointer, struct vaddy_h2_stream *s, const void *data, int length) {
    if (s->closed || length > VADDY_H2_OUTPUT - s->output_len) return -1;
    if (length) {
        if (!s->output) { s->output = malloc(VADDY_H2_OUTPUT); if (!s->output) return -1; }
        memcpy(s->output + s->output_len, data, length); s->output_len += length;
    }
    nghttp2_session_resume_data(((struct vaddy_h2 *)pointer)->session, s->id);
    return 0;
}
// The boundary uses NUL-separated names and values, avoiding C string parsing
// of header delimiters. nghttp2 copies the fields before this call returns.
static int vaddy_h2_response(void *pointer, struct vaddy_h2_stream *s, const void *raw, int length, int informational) {
    const unsigned char *data = raw;
    nghttp2_nv fields[129]; size_t count = 0, position = 0;
    while (position < (size_t)length) {
        if (count == 129) return -1;
        const unsigned char *name = data + position;
        const unsigned char *end = memchr(name, 0, length - position);
        if (!end) return -1;
        size_t namelen = (size_t)(end - name); position += namelen + 1;
        const unsigned char *value = data + position;
        end = memchr(value, 0, length - position);
        if (!end) return -1;
        size_t valuelen = (size_t)(end - value); position += valuelen + 1;
        fields[count++] = (nghttp2_nv){(uint8_t *)name, (uint8_t *)value, namelen, valuelen, NGHTTP2_NV_FLAG_NONE};
    }
    struct vaddy_h2 *h = pointer;
    if (informational) return nghttp2_submit_headers(h->session, NGHTTP2_FLAG_NONE, s->id, NULL, fields, count, NULL) < 0 ? -1 : 0;
    nghttp2_data_provider provider = {{0}, vaddy_h2_read_data}; provider.source.ptr = s;
    s->response_started = 1;
    return nghttp2_submit_response(h->session, s->id, fields, count, &provider);
}
static void vaddy_h2_end(void *pointer, struct vaddy_h2_stream *s) {
    s->response_end = 1;
    nghttp2_session_resume_data(((struct vaddy_h2 *)pointer)->session, s->id);
}
static void vaddy_h2_reset(void *pointer, int id, int code) {
    nghttp2_submit_rst_stream(((struct vaddy_h2 *)pointer)->session, NGHTTP2_FLAG_NONE, id, (uint32_t)code);
}
static void vaddy_h2_remove(void *pointer, struct vaddy_h2_stream *s) {
    struct vaddy_h2 *h = pointer;
    if (s->input_len) nghttp2_session_consume_connection(h->session, s->input_len);
    struct vaddy_h2_stream **cursor = &h->streams;
    while (*cursor && *cursor != s) cursor = &(*cursor)->next;
    if (*cursor) { *cursor = s->next; h->stream_count--; }
    nghttp2_session_set_stream_user_data(h->session, s->id, NULL);
    free(s->headers); free(s->input); free(s->output); free(s);
}
static void vaddy_h2_drain(void *pointer) {
    struct vaddy_h2 *h = pointer;
    if (h->draining) return;
    h->draining = 1;
    nghttp2_submit_goaway(h->session, NGHTTP2_FLAG_NONE,
        nghttp2_session_get_last_proc_stream_id(h->session), NGHTTP2_NO_ERROR, NULL, 0);
}
static int vaddy_h2_wants_write(void *pointer) {
    struct vaddy_h2 *h = pointer;
    return h->wire_len || nghttp2_session_want_write(h->session);
}
static int vaddy_h2_finished(void *pointer) {
    struct vaddy_h2 *h = pointer;
    return !h->wire_len && !nghttp2_session_want_read(h->session) && !nghttp2_session_want_write(h->session);
}
#endif
