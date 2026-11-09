/*
 * FuzzServer: the bytes a Modbus/TCP client sends to a libmodbus server.
 *
 * Ported from OSS-Fuzz's projects/libmodbus/fuzz/FuzzServer.c. That harness binds 127.0.0.1:8080 and
 * feeds the input from a connecting thread; here the input is written into a socketpair that is
 * installed as the context's socket, so the same modbus_receive() path runs without a fixed port or
 * threads. modbus_reply() is added so request handling (not only framing) is fuzzed too.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <modbus.h>
#include "unit-test.h"

#define MAX_INPUT_LENGTH MODBUS_TCP_MAX_ADU_LENGTH

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size > MAX_INPUT_LENGTH) /* one TCP ADU: all the library reads (and bounds the socketpair write) */
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
    modbus_mapping_t *mb_mapping = modbus_mapping_new_start_address(UT_BITS_ADDRESS,
                                                                    UT_BITS_NB,
                                                                    UT_INPUT_BITS_ADDRESS,
                                                                    UT_INPUT_BITS_NB,
                                                                    UT_REGISTERS_ADDRESS,
                                                                    UT_REGISTERS_NB_MAX,
                                                                    UT_INPUT_REGISTERS_ADDRESS,
                                                                    UT_INPUT_REGISTERS_NB);
    uint8_t *query = malloc(MODBUS_TCP_MAX_ADU_LENGTH);
    if (ctx == NULL || mb_mapping == NULL || query == NULL)
        abort();

    modbus_set_bits_from_bytes(mb_mapping->tab_input_bits, 0, UT_INPUT_BITS_NB, UT_INPUT_BITS_TAB);
    for (int i = 0; i < UT_INPUT_REGISTERS_NB; i++)
        mb_mapping->tab_input_registers[i] = UT_INPUT_REGISTERS_TAB[i];

    modbus_set_socket(ctx, sv[0]);
    modbus_set_response_timeout(ctx, 0, 1000);
    int rc = modbus_receive(ctx, query);
    if (rc > 0)
        modbus_reply(ctx, query, rc, mb_mapping);

    free(query);
    modbus_mapping_free(mb_mapping);
    modbus_free(ctx);
    close(sv[0]);
    close(sv[1]);
    return 0;
}
