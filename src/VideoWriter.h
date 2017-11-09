//
//  VideoWriter.h
//  Created by lukasz karluk on 15/06/12.
//  http://www.julapy.com
//

#import <AVFoundation/AVFoundation.h>

@protocol VideoWriterDelegate <NSObject>
@optional
- (void)videoWriterComplete:(NSURL *)url;
- (void)videoWriterCancelled;
- (void)videoWriterSavedToCameraRoll;
- (void)videoWriterError:(NSError *)error;
- (void)videoWriterLog:(NSString *)message;
@end

@interface VideoWriter : NSObject {
    id<VideoWriterDelegate> __unsafe_unretained delegate;
    dispatch_queue_t videoWriterQueue;
}

@property(unsafe_unretained) id <VideoWriterDelegate> delegate;

@property(nonatomic, assign) CGSize videoSize;
@property(nonatomic, retain) EAGLContext * context;
@property(nonatomic, retain) AVAssetWriter * assetWriter;
@property(nonatomic, retain) AVAssetWriterInput * assetWriterVideoInput;
@property(nonatomic, retain) AVAssetWriterInput * assetWriterAudioInput;
@property(nonatomic, retain) AVAssetWriterInputPixelBufferAdaptor * assetWriterInputPixelBufferAdaptor;
@property(nonatomic, retain) NSURL * outputURL;
@property(nonatomic, assign) BOOL enableTextureCache;
@property(nonatomic, assign) BOOL expectsMediaDataInRealTime;
@property(nonatomic, assign) int bitrate;

@property(nonatomic, retain) AVCaptureDeviceInput * captureInput;
@property(nonatomic, retain) AVCaptureAudioDataOutput * captureOutput;
@property(nonatomic, retain) AVCaptureSession * captureSession;

- (id)initWithFile:(NSString *)file andVideoSize:(CGSize)size;
- (id)initWithPath:(NSString *)path andVideoSize:(CGSize)size;
- (id)initWithURL:(NSURL *)fileURL andVideoSize:(CGSize)size;

- (void)startRecording:(NSString *) rotation;
- (void)cancelRecording;
- (void)finishRecording;
- (BOOL)isWriting;

- (BOOL)addFrameAtTime:(CMTime)frameTime;
- (BOOL)addAudio:(CMSampleBufferRef)audioBuffer;

- (BOOL)isTextureCached;
- (unsigned int)textureCacheID;
- (int)textureCacheTarget;

- (void)saveMovieToCameraRoll;

@end
