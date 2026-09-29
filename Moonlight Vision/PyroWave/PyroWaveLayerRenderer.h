//
//  PyroWaveLayerRenderer.h
//  Moonlight Vision
//
//  PyroWave presentation for the UIKit (classic) stream view: decodes each frame on the GPU
//  and draws it straight into an EDR CAMetalLayer, in place of AVSampleBufferDisplayLayer.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface PyroWaveLayerRenderer : NSObject

/// The layer to insert into the stream view. Configure its frame on the main thread.
@property (nonatomic, readonly) CAMetalLayer *layer;

- (nullable instancetype)initWithWidth:(NSInteger)width
                                height:(NSInteger)height
                             chroma444:(BOOL)chroma444
                     firstFrameHandler:(void (^)(void))firstFrameHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes and presents one Moonlight PYRW frame. Safe to call from any single thread.
/// Frames arriving while the GPU still has several in flight are dropped.
- (void)submitFrame:(const uint8_t *)data length:(size_t)length;

@end

NS_ASSUME_NONNULL_END
