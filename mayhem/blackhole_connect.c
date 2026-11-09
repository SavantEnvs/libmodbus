/*
 * LD_PRELOAD shim for mayhem/test.sh. unit-test-client's "8/8 Connection timeout" check connects to
 * 1.2.3.4 and expects ETIMEDOUT, which only happens on a host with a route to the internet; offline it
 * gets ENETUNREACH and the client aborts mid-suite. Make 1.2.3.4 behave as a blackhole: connect()
 * fails with ETIMEDOUT, which is what a routed-but-silent address ends in.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <netinet/in.h>
#include <sys/socket.h>

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    static int (*real_connect)(int, const struct sockaddr *, socklen_t);
    if (addr != NULL && addr->sa_family == AF_INET
        && ((const struct sockaddr_in *) addr)->sin_addr.s_addr == htonl(0x01020304)) {
        errno = ETIMEDOUT;
        return -1;
    }
    if (real_connect == NULL)
        real_connect = (int (*)(int, const struct sockaddr *, socklen_t)) dlsym(RTLD_NEXT, "connect");
    return real_connect(fd, addr, len);
}
