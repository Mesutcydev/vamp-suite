/* Non-variadic shims over opus_encoder_ctl(), which Swift cannot call (C variadics
 * are unavailable to Swift). Keeps the codec controls reachable from the Swift wrapper. */
#ifndef COPUS_HELPERS_H
#define COPUS_HELPERS_H

#include "opus.h"

int copus_encoder_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate);

#endif /* COPUS_HELPERS_H */
