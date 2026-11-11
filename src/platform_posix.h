#ifndef VADDY_PLATFORM_POSIX_H
#define VADDY_PLATFORM_POSIX_H
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#if defined(__linux__)
#include <sys/epoll.h>
#else
#include <sys/event.h>
#endif

static volatile sig_atomic_t vaddy_stopping;
static volatile sig_atomic_t vaddy_reload_requested;
static void vaddy_private_files(void) { umask(0077); }
static int vaddy_socket_alive(int fd) {
    char byte; int n = (int)recv(fd, &byte, 1, MSG_PEEK);
    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
}
static void vaddy_signal(int sig) { if (sig == SIGHUP) vaddy_reload_requested = 1; else vaddy_stopping = 1; }
static void vaddy_signals(void) {
    struct sigaction sa = {0}; sa.sa_handler = vaddy_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
}
static int vaddy_stopped(void) { return vaddy_stopping; }
static int vaddy_take_reload(void) {
    sigset_t block, previous;
    sigemptyset(&block); sigaddset(&block, SIGHUP);
    sigprocmask(SIG_BLOCK, &block, &previous);
    int requested = vaddy_reload_requested; vaddy_reload_requested = 0;
    sigprocmask(SIG_SETMASK, &previous, NULL);
    return requested;
}
static int vaddy_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return -1;
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return 0;
}
static int vaddy_wakeup_pair(int64_t *fds) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return -1;
    fds[0] = pair[0]; fds[1] = pair[1];
    if (vaddy_nonblock(fds[0]) || vaddy_nonblock(fds[1])) {
        close(fds[0]); close(fds[1]); return -1;
    }
    return 0;
}
static int vaddy_notify(int fd) {
    char byte = 1; int n;
    do { n = (int)send(fd, &byte, 1, 0); } while (n < 0 && errno == EINTR);
    return n == 1 || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? 0 : -1;
}
struct vaddy_address { struct sockaddr_storage addr; socklen_t len; };
static struct vaddy_address *vaddy_resolve(const char *host, const char *port) {
    struct addrinfo hints = {0}, *list = NULL, *item = NULL;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &list)) return NULL;
    /* Prefer IPv4 for localhost, whose backend often only binds 127.0.0.1. */
    for (item = list; item && item->ai_family != AF_INET; item = item->ai_next) {}
    if (!item) item = list;
    struct vaddy_address *out = calloc(1, sizeof *out);
    if (out && item && item->ai_addrlen <= sizeof out->addr) {
        memcpy(&out->addr, item->ai_addr, item->ai_addrlen); out->len = item->ai_addrlen;
    } else { free(out); out = NULL; }
    freeaddrinfo(list); return out;
}
static int vaddy_connect(struct vaddy_address *addr) {
    int fd = socket(addr->addr.ss_family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (vaddy_nonblock(fd) || (connect(fd, (struct sockaddr *)&addr->addr, addr->len) < 0 && errno != EINPROGRESS)) { close(fd); return -1; }
    return fd;
}
static int vaddy_connected(int fd) {
    int err = 0; socklen_t len = sizeof err;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) || err) return -1;
    struct sockaddr_storage peer; len = sizeof peer;
    if (!getpeername(fd, (struct sockaddr *)&peer, &len)) return 0;
    return errno == ENOTCONN ? 1 : -1;
}
static int vaddy_listen(const char *host, const char *port) {
    struct addrinfo hints = {0}, *list, *it; int fd = -1, one = 1, zero = 0;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
    if (getaddrinfo(host, port, &hints, &list)) return -1;
    for (it = list; it; it = it->ai_next) {
        fd = socket(it->ai_family, SOCK_STREAM, 0); if (fd < 0) continue;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (it->ai_family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
        if (!vaddy_nonblock(fd) && !bind(fd, it->ai_addr, it->ai_addrlen) && !listen(fd, 256)) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(list); return fd;
}
static int vaddy_accept(int fd, char *ip, int len) {
    struct sockaddr_storage addr; socklen_t size = sizeof addr;
    int client = accept(fd, (struct sockaddr *)&addr, &size);
    if (client < 0) return -1;
    if (vaddy_nonblock(client) || getnameinfo((struct sockaddr *)&addr, size, ip, len, NULL, 0, NI_NUMERICHOST)) { close(client); return -1; }
    if (!strncmp(ip, "::ffff:", 7)) memmove(ip, ip + 7, strlen(ip + 7) + 1);
    return client;
}
static int vaddy_again(void) { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR; }
static int vaddy_lock(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB)) { close(fd); fd = -1; }
    return fd;
}
struct vaddy_event { int fd, flags; };
static int vaddy_queue(void) {
#if defined(__linux__)
    return epoll_create1(EPOLL_CLOEXEC);
#else
    int fd = kqueue(); if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC); return fd;
#endif
}
static int vaddy_watch(int q, int fd, int old, int flags) {
#if defined(__linux__)
    struct epoll_event e = {0}; e.data.fd = fd;
    e.events = ((flags & 1) ? EPOLLIN : 0) | ((flags & 2) ? EPOLLOUT : 0);
    if (!flags) return old ? epoll_ctl(q, EPOLL_CTL_DEL, fd, NULL) : 0;
    return epoll_ctl(q, old ? EPOLL_CTL_MOD : EPOLL_CTL_ADD, fd, &e);
#else
    struct kevent events[2]; int n = 0;
    if ((old ^ flags) & 1) { EV_SET(&events[n], fd, EVFILT_READ, (flags & 1) ? EV_ADD : EV_DELETE, 0, 0, NULL); n++; }
    if ((old ^ flags) & 2) { EV_SET(&events[n], fd, EVFILT_WRITE, (flags & 2) ? EV_ADD : EV_DELETE, 0, 0, NULL); n++; }
    return n ? kevent(q, events, n, NULL, 0, NULL) : 0;
#endif
}
static int vaddy_wait(int q, struct vaddy_event *out, int max, int ms) {
    if (max > 256) max = 256;
#if defined(__linux__)
    struct epoll_event ev[256]; int n = epoll_wait(q, ev, max, ms);
    for (int i = 0; i < n; i++) { out[i].fd = ev[i].data.fd; out[i].flags = ((ev[i].events & EPOLLIN) ? 1 : 0) | ((ev[i].events & EPOLLOUT) ? 2 : 0) | ((ev[i].events & (EPOLLERR | EPOLLHUP)) ? 4 : 0); }
#else
    struct kevent ev[256]; struct timespec timeout = {ms / 1000, (ms % 1000) * 1000000};
    int n = kevent(q, NULL, 0, ev, max, &timeout);
    for (int i = 0; i < n; i++) { out[i].fd = (int)ev[i].ident; out[i].flags = (ev[i].filter == EVFILT_READ ? 1 : 2) | ((ev[i].flags & (EV_EOF | EV_ERROR)) ? 4 : 0); }
#endif
    return n;
}

static int vaddy_close(int fd) { return close(fd); }
static void vaddy_queue_close(int q) { close(q); }
static void vaddy_unlock(int fd) { close(fd); }
static long long vaddy_recv(int fd, void *buf, size_t len, int flags) { return recv(fd, buf, len, flags); }
static long long vaddy_send(int fd, const void *buf, size_t len, int flags) { return send(fd, buf, len, flags); }
static int vaddy_replace(const char *src, const char *dst) { return rename(src, dst); }

#endif
