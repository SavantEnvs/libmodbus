/*
 * FuzzClient: the bytes a Modbus/TCP server sends back to a libmodbus client.
 *
 * Ported from OSS-Fuzz's projects/libmodbus/fuzz/FuzzClient.c. That harness runs a listening thread on
 * 127.0.0.1:8080 that answers each of the client's two requests with the input; here the input is
 * queued twice on a socketpair installed as the context's socket, which presents the same byte stream
 * to modbus_read_bits() and modbus_read_registers() without a fixed port or threads.
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
    if (write(sv[1], data, size) != (ssize_t) size || write(sv[1], data, size) != (ssize_t) size) {
        close(sv[0]);
        close(sv[1]);
        return -1;
    }
    shutdown(sv[1], SHUT_WR);

    modbus_t *ctx = modbus_new_tcp("127.0.0.1", 1502);
    int nb_bits = UT_BITS_NB > UT_INPUT_BITS_NB ? UT_BITS_NB : UT_INPUT_BITS_NB;
    int nb_regs = UT_REGISTERS_NB > UT_INPUT_REGISTERS_NB ? UT_REGISTERS_NB : UT_INPUT_REGISTERS_NB;
    uint8_t *tab_rp_bits = calloc(nb_bits, sizeof(uint8_t));
    uint16_t *tab_rp_registers = calloc(nb_regs, sizeof(uint16_t));
    if (ctx == NULL || tab_rp_bits == NULL || tab_rp_registers == NULL)
        abort();

    modbus_set_socket(ctx, sv[0]);
    modbus_set_response_timeout(ctx, 0, 1000);
    modbus_read_bits(ctx, UT_BITS_ADDRESS, UT_BITS_NB, tab_rp_bits);
    modbus_read_registers(ctx, UT_REGISTERS_ADDRESS, UT_REGISTERS_NB, tab_rp_registers);

    free(tab_rp_bits);
    free(tab_rp_registers);
    modbus_free(ctx);
    close(sv[0]);
    close(sv[1]);
    return 0;
}
