//
//  PyroWaveFrameDecoder.mm
//  Moonlight Vision
//

#import "PyroWaveFrameDecoder.h"
#include "metal/pyrowave_metal.h"

// Moonlight PyroWave frame container, as sent by PyroWave-enabled Vibepollo hosts:
// "PYRW", version byte, big-endian u16 packet count, flags byte, then per packet a
// big-endian u32 length followed by the packet bytes.
static const size_t kFrameHeaderSize = 8;
static const uint8_t kFrameVersion = 1;
// Flags: full range, centre-sited chroma. Hosts that predate the flag send zero.
static const uint8_t kFlagFullRangeCenterChroma = 0x01;

static uint32_t readBe32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void logMessage(void *, const char *msg)
{
    NSLog(@"[PyroWave] %s", msg);
}

@implementation PyroWaveFrameDecoder {
    pyrowave_device _device;
    pyrowave_decoder _decoder;
}

+ (BOOL)isSupportedOnDevice:(id<MTLDevice>)device
{
    return pyrowave_device_is_supported((__bridge void *)device);
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  width:(NSInteger)width
                                 height:(NSInteger)height
                              chroma444:(BOOL)chroma444
{
    if ((self = [super init])) {
        _chroma444 = chroma444;

        pyrowave_device_create_info deviceInfo = {};
        deviceInfo.mtl_device = (__bridge void *)device;
        deviceInfo.message_callback = logMessage;
        pyrowave_result res = pyrowave_device_create(&deviceInfo, &_device);
        if (res != PYROWAVE_SUCCESS) {
            NSLog(@"[PyroWave] Device creation failed: %s", pyrowave_result_to_string(res));
            return nil;
        }

        pyrowave_decoder_create_info decoderInfo = {};
        decoderInfo.device = _device;
        decoderInfo.width = (int)width;
        decoderInfo.height = (int)height;
        decoderInfo.chroma = chroma444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
        res = pyrowave_decoder_create(&decoderInfo, &_decoder);
        if (res != PYROWAVE_SUCCESS) {
            NSLog(@"[PyroWave] Decoder creation failed for %ldx%ld: %s",
                  (long)width, (long)height, pyrowave_result_to_string(res));
            return nil;
        }

        NSInteger chromaWidth = chroma444 ? width : width / 2;
        NSInteger chromaHeight = chroma444 ? height : height / 2;
        _yPlane = [self makePlaneOnDevice:device width:width height:height label:@"PyroWave Y"];
        _cbPlane = [self makePlaneOnDevice:device width:chromaWidth height:chromaHeight label:@"PyroWave Cb"];
        _crPlane = [self makePlaneOnDevice:device width:chromaWidth height:chromaHeight label:@"PyroWave Cr"];
        if (!_yPlane || !_cbPlane || !_crPlane) {
            return nil;
        }
    }
    return self;
}

- (nullable id<MTLTexture>)makePlaneOnDevice:(id<MTLDevice>)device
                                       width:(NSInteger)width
                                      height:(NSInteger)height
                                       label:(NSString *)label
{
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    texture.label = label;
    return texture;
}

- (void)dealloc
{
    if (_decoder) {
        pyrowave_decoder_destroy(_decoder);
    }
    if (_device) {
        pyrowave_device_destroy(_device);
    }
}

- (BOOL)pushFrame:(const uint8_t *)data length:(size_t)length
{
    if (length < kFrameHeaderSize || memcmp(data, "PYRW", 4) != 0 ||
        data[4] != kFrameVersion || (data[7] & ~kFlagFullRangeCenterChroma) != 0) {
        pyrowave_decoder_clear(_decoder);
        return NO;
    }
    _fullRangeCenterChroma = (data[7] & kFlagFullRangeCenterChroma) != 0;

    const size_t packetCount = ((size_t)data[5] << 8) | data[6];
    size_t offset = kFrameHeaderSize;
    for (size_t i = 0; i < packetCount; i++) {
        if (length - offset < 4) {
            pyrowave_decoder_clear(_decoder);
            return NO;
        }
        const uint32_t packetSize = readBe32(data + offset);
        offset += 4;
        if (packetSize == 0 || packetSize > length - offset ||
            pyrowave_decoder_push_packet(_decoder, data + offset, packetSize) != PYROWAVE_SUCCESS) {
            pyrowave_decoder_clear(_decoder);
            return NO;
        }
        offset += packetSize;
    }
    return packetCount > 0 && offset == length;
}

- (BOOL)encodeDecodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    // Intra-only: a frame missing packets still decodes, with lost detail.
    if (!pyrowave_decoder_decode_is_ready(_decoder, true)) {
        return NO;
    }

    pyrowave_gpu_buffers buffers = {};
    buffers.planes[0] = (__bridge void *)_yPlane;
    buffers.planes[1] = (__bridge void *)_cbPlane;
    buffers.planes[2] = (__bridge void *)_crPlane;
    pyrowave_result res = pyrowave_decoder_decode_gpu_buffer(_decoder, (__bridge void *)commandBuffer, &buffers);
    if (res != PYROWAVE_SUCCESS) {
        NSLog(@"[PyroWave] Decode failed: %s", pyrowave_result_to_string(res));
        return NO;
    }
    return YES;
}

- (void)reset
{
    pyrowave_decoder_clear(_decoder);
}

@end
