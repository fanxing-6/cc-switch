#include <stdint.h>

void *ccs_gateway_start(const char *configuration, uint16_t *port);
void ccs_gateway_stop(void *gateway);
