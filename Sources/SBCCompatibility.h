#ifndef AM_SBC_COMPATIBILITY_H
#define AM_SBC_COMPATIBILITY_H
// Provide GNU byte-order names expected by unmodified upstream libsbc on Darwin.
#ifndef __BYTE_ORDER
#define __BYTE_ORDER __BYTE_ORDER__
#endif
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN __ORDER_LITTLE_ENDIAN__
#endif
#ifndef __BIG_ENDIAN
#define __BIG_ENDIAN __ORDER_BIG_ENDIAN__
#endif
#endif
