/*
 * The two functions vendor/mbedtls_config_ios6.h asks the platform for (vendor/mbedtls_glue.c on iOS), for a desktop
 * Linux build of tools/tls-probe.
 */
#include "mbedtls/build_info.h"
#include "mbedtls/platform_time.h"
#include "mbedtls/entropy.h"
#include "entropy_poll.h"

#include <stddef.h>
#include <sys/time.h>
#include <sys/random.h>

#if defined(MBEDTLS_PLATFORM_MS_TIME_ALT)
mbedtls_ms_time_t mbedtls_ms_time(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (mbedtls_ms_time_t)tv.tv_sec * 1000 + (mbedtls_ms_time_t)(tv.tv_usec / 1000);
}
#endif

#if defined(MBEDTLS_ENTROPY_HARDWARE_ALT)
int mbedtls_hardware_poll(void *data, unsigned char *output, size_t len, size_t *olen)
{
    (void)data;
    ssize_t n = getrandom(output, len, 0);
    if (n < 0) {
        *olen = 0;
        return MBEDTLS_ERR_ENTROPY_SOURCE_FAILED;
    }
    *olen = (size_t)n;
    return 0;
}
#endif
