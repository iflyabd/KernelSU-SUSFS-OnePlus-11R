/* Host compat for Termux bionic (glibc bits bionic elf.h lacks). Host builds only. */
#ifndef _HOST_COMPAT_H
#define _HOST_COMPAT_H
#ifndef ELF32_ST_TYPE
#define ELF32_ST_TYPE(i) ((i) & 0xf)
#endif
#ifndef ELF64_ST_TYPE
#define ELF64_ST_TYPE(i) ((i) & 0xf)
#endif
#endif
