//
//  PyroWaveLayerRenderer.m
//  Moonlight Vision
//

#import "PyroWaveLayerRenderer.h"
#import "PyroWaveFrameDecoder.h"
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

// Must match the structs in Shaders.metal.
typedef struct {
    uint32_t is10Bit;
    uint32_t isFullRange;
    uint32_t isPQ;
    uint32_t matrixType;
    uint32_t primariesType;
    uint32_t isTargetDisplayP3;
} PWHDRParams;

typedef struct {
    float boost;
    float contrast;
    float saturation;
    float brightness;
    float pqExposure;
    int32_t mode;
} PWFullHDRParams;

typedef struct {
    float saturation;
    float contrast;
    float warmth;
    float padding1;
} PWColorEnhancementUniforms;

static const long kMaxFramesInFlight = 3;

@implementation PyroWaveLayerRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    PyroWaveFrameDecoder *_decoder;
    dispatch_semaphore_t _inflight;
    void (^_firstFrameHandler)(void);
    BOOL _firstFrameShown;
}

- (nullable instancetype)initWithWidth:(NSInteger)width
                                height:(NSInteger)height
                             chroma444:(BOOL)chroma444
                     firstFrameHandler:(void (^)(void))firstFrameHandler
{
    if ((self = [super init])) {
        _device = MTLCreateSystemDefaultDevice();
        _queue = [_device newCommandQueue];
        if (!_device || !_queue) {
            return nil;
        }

        // 16-bit planes so HDR10 streams keep their precision; SDR streams simply use them too.
        _decoder = [[PyroWaveFrameDecoder alloc] initWithDevice:_device width:width height:height
                                                      chroma444:chroma444 highPrecision:YES];
        if (!_decoder) {
            return nil;
        }

        // Extended linear Display P3 in EDR units: the shared shader maps SDR white to 1.0 and
        // PQ to absolute brightness above it, for both SDR and HDR10 frames.
        _layer = [CAMetalLayer layer];
        _layer.device = _device;
        _layer.pixelFormat = MTLPixelFormatRGBA16Float;
        _layer.wantsExtendedDynamicRangeContent = YES;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
        _layer.colorspace = colorSpace;
        CGColorSpaceRelease(colorSpace);
        _layer.framebufferOnly = YES;
        _layer.drawableSize = CGSizeMake(width, height);
        // Two drawables: frames are presented as soon as they are decoded, so a third would only
        // add a frame of queueing when the compositor falls behind.
        _layer.maximumDrawableCount = 2;
        _layer.backgroundColor = UIColor.blackColor.CGColor;
        _layer.hidden = YES;

        id<MTLLibrary> library = [_device newDefaultLibrary];
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = @"PyroWave UIKit";
        desc.vertexFunction = [library newFunctionWithName:@"copyVertexShader"];
        desc.fragmentFunction = [library newFunctionWithName:@"copyFragmentShaderPyroWave"];
        desc.colorAttachments[0].pixelFormat = _layer.pixelFormat;
        NSError *error = nil;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_pipeline) {
            NSLog(@"[PyroWave] UIKit pipeline creation failed: %@", error);
            return nil;
        }

        _inflight = dispatch_semaphore_create(kMaxFramesInFlight);
        _firstFrameHandler = [firstFrameHandler copy];
    }
    return self;
}

- (void)submitFrame:(const uint8_t *)data length:(size_t)length
{
    // Intra-only: a malformed or lost frame is skipped and the next one recovers on its own.
    if (![_decoder pushFrame:data length:length]) {
        return;
    }
    // Drop rather than queue when the GPU is behind; the next frame replaces this one.
    if (dispatch_semaphore_wait(_inflight, DISPATCH_TIME_NOW) != 0) {
        [_decoder reset];
        return;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> cmd = [_queue commandBuffer];
        cmd.label = @"PyroWave UIKit frame";
        dispatch_semaphore_t inflight = _inflight;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            dispatch_semaphore_signal(inflight);
        }];

        id<CAMetalDrawable> drawable = nil;
        if (![_decoder encodeDecodeToCommandBuffer:cmd] || !(drawable = [_layer nextDrawable])) {
            [cmd commit];
            return;
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:_pipeline];
        [enc setFragmentTexture:_decoder.yPlane atIndex:0];
        [enc setFragmentTexture:_decoder.cbPlane atIndex:1];
        [enc setFragmentTexture:_decoder.crPlane atIndex:2];

        const BOOL hdr10 = _decoder.hdr10;
        const BOOL fullRange = _decoder.fullRangeCenterChroma;
        PWHDRParams params = {
            .is10Bit = 0,
            .isFullRange = fullRange ? 1 : 0,
            .isPQ = hdr10 ? 1 : 0,
            .matrixType = hdr10 ? 1 : 0,     // BT.2020 : BT.709
            .primariesType = hdr10 ? 1 : 0,  // BT.2020 : BT.709
            .isTargetDisplayP3 = 1,
        };
        PWFullHDRParams full = { .boost = 1, .contrast = 1, .saturation = 1, .brightness = 0, .pqExposure = 1, .mode = 1 };
        PWColorEnhancementUniforms enhancements = { .saturation = 1, .contrast = 1, .warmth = 0, .padding1 = 0 };
        uint32_t chromaCosited = fullRange ? 0 : 1;
        [enc setFragmentBytes:&params length:sizeof(params) atIndex:0];
        [enc setFragmentBytes:&full length:sizeof(full) atIndex:1];
        [enc setFragmentBytes:&enhancements length:sizeof(enhancements) atIndex:2];
        [enc setFragmentBytes:&chromaCosited length:sizeof(chromaCosited) atIndex:3];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];

        [cmd presentDrawable:drawable];
        [cmd commit];
    }

    if (!_firstFrameShown) {
        _firstFrameShown = YES;
        CAMetalLayer *layer = _layer;
        void (^handler)(void) = _firstFrameHandler;
        dispatch_async(dispatch_get_main_queue(), ^{
            layer.hidden = NO;
            if (handler) {
                handler();
            }
        });
    }
}

@end
