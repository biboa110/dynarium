/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef UML_DARWIN_ELF_LOADER_H
#define UML_DARWIN_ELF_LOADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A nonzero window_end names a host reservation, [window_start, window_end),
 * that the image must lie inside; the loader then maps the image over it in
 * place and hands the image's range back to it when the kernel returns.
 * Without one, the image is placed by an address hint that must be honoured.
 */
int uml_elf_run(const void *image, size_t image_size, uintptr_t load_bias,
		uintptr_t window_start, uintptr_t window_end,
		int argc, char **argv, char **envp);

/* Copies the last loader failure message (up to buffer_size - 1 bytes) into
 * buffer and returns its byte length. */
size_t uml_elf_copy_last_error(char *buffer, size_t buffer_size);

#ifdef __cplusplus
}
#endif

#endif
