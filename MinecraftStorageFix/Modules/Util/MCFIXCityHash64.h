//
//  MCFIXCityHash64.h — Google CityHash64 (matches IDA __hidden_1946_ @ 0x101092DEC)
//

#ifndef MCFIXCityHash64_h
#define MCFIXCityHash64_h

#include <stddef.h>
#include <stdint.h>

uint64_t MCFIXCityHash64(const void *data, size_t len);

#endif /* MCFIXCityHash64_h */
