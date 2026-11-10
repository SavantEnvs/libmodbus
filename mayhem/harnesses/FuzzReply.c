/*
 * FuzzReply: an arbitrary Modbus/TCP request handed straight to modbus_reply().
 *
 * modbus_reply(ctx, req, req_length, mapping) is exported and takes the request length as an argument,
 * so a caller that does its own receive (a gateway, a UDP or custom transport) may pass it any length.
 * Here the request is a heap block of exactly req_length bytes, so a handler reading past the declared
 * length is an out-of-bounds read. The response goes to a socketpair that is never read.
 *
 * A request is what modbus_receive() returned, and that returns only once it has read the 7-byte MBAP
 * header and the function code (docs/modbus_reply.md: "a response to received request"), so shorter
 * input is rejected. Anything longer is passed as is: how much of the PDU follows is the caller's.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#include <modbus.h>
#include "unit-test.h"

#define MIN_REQUEST_LENGTH (7 + 1)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < MIN_REQUEST_LENGTH || size > MODBUS_TCP_MAX_ADU_LENGTH)
        return -1;

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
        return -1;

    modbus_t *ctx = modbus_new_tcp("127.0.0.1", 1502);
    modbus_mapping_t *mb_mapping = modbus_mapping_new_start_address(UT_BITS_ADDRESS,
                                                                    UT_BITS_NB,
                                                                    UT_INPUT_BITS_ADDRESS,
                                                                    UT_INPUT_BITS_NB,
                                                                    UT_REGISTERS_ADDRESS,
                                                                    UT_REGISTERS_NB_MAX,
                                                                    UT_INPUT_REGISTERS_ADDRESS,
                                                                    UT_INPUT_REGISTERS_NB);
    uint8_t *req = malloc(size ? size : 1);
    if (ctx == NULL || mb_mapping == NULL || req == NULL)
        abort();

    for (size_t i = 0; i < size; i++)
        req[i] = data[i];

    modbus_set_bits_from_bytes(mb_mapping->tab_input_bits, 0, UT_INPUT_BITS_NB, UT_INPUT_BITS_TAB);
    for (int i = 0; i < UT_INPUT_REGISTERS_NB; i++)
        mb_mapping->tab_input_registers[i] = UT_INPUT_REGISTERS_TAB[i];

    modbus_set_socket(ctx, sv[0]);
    modbus_reply(ctx, req, (int) size, mb_mapping);

    free(req);
    modbus_mapping_free(mb_mapping);
    modbus_free(ctx);
    close(sv[0]);
    close(sv[1]);
    return 0;
}
