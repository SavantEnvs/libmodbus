/*
 * mayhem_fuzzer: Modbus/TCP request parsing and reply generation.
 *
 * Ported from the legacy mayhemheroes/libmodbus harness (mayhem-fuzzer.c). The input is written into a
 * socketpair installed as the context's socket; modbus_receive() frames the request and modbus_reply()
 * answers it from a 500-entry mapping of every table type. Unlike the legacy harness, an input longer
 * than one ADU is rejected rather than truncated.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#include "modbus.h"
#include "modbus-tcp.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size > MODBUS_TCP_MAX_ADU_LENGTH) /* one TCP ADU: all the library reads */
        return -1;

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
        return -1;
    if (write(sv[1], data, size) != (ssize_t) size) {
        close(sv[0]);
        close(sv[1]);
        return -1;
    }
    shutdown(sv[1], SHUT_WR);

    modbus_t *ctx = modbus_new_tcp("127.0.0.1", 1502);
    modbus_mapping_t *mb_mapping = modbus_mapping_new(500, 500, 500, 500);
    if (ctx == NULL || mb_mapping == NULL)
        abort();

    modbus_set_socket(ctx, sv[0]);
    modbus_set_response_timeout(ctx, 0, 1000);
    uint8_t req[MODBUS_TCP_MAX_ADU_LENGTH];
    int rc = modbus_receive(ctx, req);
    if (rc > 0)
        modbus_reply(ctx, req, rc, mb_mapping);

    modbus_mapping_free(mb_mapping);
    modbus_free(ctx);
    close(sv[0]);
    close(sv[1]);
    return 0;
}
