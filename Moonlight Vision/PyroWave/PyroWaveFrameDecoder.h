//
//  PyroWaveFrameDecoder.h
//  Moonlight Vision
//
//  Decodes PyroWave frames delivered by a PyroWave-enabled host into three
//  Metal plane textures (Y, Cb, Cr) using the upstream PyroWave Metal decoder.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface PyroWaveFrameDecoder : NSObject

/// Whether this Metal device can run the PyroWave decoder (Apple7 family and up).
+ (BOOL)isSupportedOnDevice:(id<MTLDevice>)device;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  width:(NSInteger)width
                                 height:(NSInteger)height
                              chroma444:(BOOL)chroma444 NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Luma plane, width x height, r8Unorm.
@property (nonatomic, readonly) id<MTLTexture> yPlane;
/// Chroma planes, half size for 4:2:0 or full size for 4:4:4, r8Unorm.
@property (nonatomic, readonly) id<MTLTexture> cbPlane;
@property (nonatomic, readonly) id<MTLTexture> crPlane;
@property (nonatomic, readonly) BOOL chroma444;
/// Colour signalling of the last pushed frame. YES: full range with centre-sited chroma
/// (hosts using PyroWave's own RGB conversion). NO: limited range with left-cosited 4:2:0 chroma.
@property (nonatomic, readonly) BOOL fullRangeCenterChroma;

/// Parses one Moonlight "PYRW" frame container and queues its packets.
/// Returns NO if the container is malformed or a packet does not parse; the
/// partially queued frame is dropped in that case.
- (BOOL)pushFrame:(const uint8_t *)data length:(size_t)length;

/// Encodes the decode of the queued frame into the command buffer, writing the
/// three plane textures. Missing packets decode as extra blur rather than failing.
/// Returns NO if there is nothing to decode or the decode could not be encoded.
- (BOOL)encodeDecodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;

/// Drops any queued packets, e.g. after the stream restarts.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
