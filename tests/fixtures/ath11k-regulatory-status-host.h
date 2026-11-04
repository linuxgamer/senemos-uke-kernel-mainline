/* SPDX-License-Identifier: BSD-3-Clause-Clear */
/* Synthetic logging boundary for unchanged Linux C diagnostic blocks only. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t u32;
struct ath11k_base { unsigned int unused; };
static char debug_text[256], warning_text[512];
static unsigned int debug_calls, warning_calls;

static void __attribute__((format(printf, 3, 4)))
capture_debug(struct ath11k_base *ab, int mask, const char *format, ...)
{
	va_list args;
	int size;
	(void)ab;
	(void)mask;
	assert(strcmp(format, "status_code %s") == 0);
	va_start(args, format);
	size = vsnprintf(debug_text, sizeof(debug_text), format, args);
	va_end(args);
	assert(size >= 0 && (size_t)size < sizeof(debug_text));
	debug_calls++;
}

static void __attribute__((format(printf, 2, 3)))
capture_warning(struct ath11k_base *ab, const char *format, ...)
{
	va_list args;
	int size;
	(void)ab;
	va_start(args, format);
	size = vsnprintf(warning_text, sizeof(warning_text), format, args);
	va_end(args);
	assert(size >= 0 && (size_t)size < sizeof(warning_text));
	warning_calls++;
}

#define ATH11K_DBG_WMI 1
#define ath11k_dbg capture_debug
#define ath11k_warn capture_warning
