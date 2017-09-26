//
//  VideoWriter.m
//  Created by lukasz karluk on 15/06/12.
//  http://www.julapy.com
//

#import <AssetsLibrary/AssetsLibrary.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "VideoWriter.h"

@interface VideoWriter() <AVCaptureAudioDataOutputSampleBufferDelegate> {
	CMTime startTime;
    CMTime previousFrameTime;
	CMTime previousAudioTime;
    BOOL bWriting;

    BOOL bUseTextureCache;
    BOOL bEnableTextureCache;
    BOOL bTextureCacheSupported;
    BOOL bMicAudio;
	BOOL bFirstAudio;
	
    CVOpenGLESTextureCacheRef _textureCache;
    CVOpenGLESTextureRef _textureRef;
    CVPixelBufferRef _textureCachePixelBuffer;
	CMSampleBufferRef _firstAudioBuffer;
}
@end


@implementation VideoWriter

@synthesize delegate;
@synthesize videoSize;
@synthesize context;
@synthesize assetWriter;
@synthesize assetWriterVideoInput;
@synthesize assetWriterAudioInput;
@synthesize assetWriterInputPixelBufferAdaptor;
@synthesize outputURL;
@synthesize enableTextureCache;
@synthesize expectsMediaDataInRealTime;

@synthesize captureInput;
@synthesize captureOutput;
@synthesize captureSession;

//---------------------------------------------------------------------------
- (id)initWithFile:(NSString *)file andVideoSize:(CGSize)size {
    NSString * docsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString * fullPath = [docsPath stringByAppendingPathComponent:file];
    NSURL * fileURL = [NSURL fileURLWithPath:fullPath];
	return [self initWithURL:fileURL andVideoSize:size];
}

- (id)initWithPath:(NSString *)path andVideoSize:(CGSize)size {
    NSURL * fileURL = [NSURL fileURLWithPath:path];
	return [self initWithURL:fileURL andVideoSize:size];
}

- (id)initWithURL:(NSURL *)fileURL andVideoSize:(CGSize)size {
    self = [self init];
    if(self) {
        self.outputURL = fileURL;
        self.videoSize = size;
    }
    return self;
}

- (id)init {
    self = [super init];
    if(self) {
        bWriting = NO;
        startTime = kCMTimeInvalid;
        previousFrameTime = kCMTimeInvalid;
		previousAudioTime = kCMTimeInvalid;
        videoWriterQueue = dispatch_queue_create("ofxiOSVideoWriter.VideoWriterQueue", NULL);

        bUseTextureCache = NO;
        bEnableTextureCache = NO;
        bTextureCacheSupported = NO;
        bMicAudio = NO;
        bFirstAudio = NO;
        expectsMediaDataInRealTime = YES;
    }
    return self;
}

- (void)dealloc {
    self.outputURL = nil;
    
    [self cancelRecording];
	
	if(_firstAudioBuffer) {
		CFRelease(_firstAudioBuffer);
	}
    
#if ( (__IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_6_0) || (!defined(__IPHONE_6_0)) )
    if(videoWriterQueue != NULL) {
        dispatch_release(videoWriterQueue);
    }
#endif
    
}

//---------------------------------------------------------------------------
- (void)startRecording:(NSString *) rotation {
    if(bWriting == YES) {
        return;
    }
    bWriting = YES;
    
    startTime = kCMTimeZero;
    previousFrameTime = kCMTimeInvalid;
	bFirstAudio = YES;
	if(_firstAudioBuffer) {
		CFRelease(_firstAudioBuffer);
	}
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.outputURL.path]) { // remove old file.
        [[NSFileManager defaultManager] removeItemAtPath:self.outputURL.path error:nil];
    }
    
    // allocate the writer object with our output file URL
    NSError *error = nil;
    self.assetWriter = [AVAssetWriter assetWriterWithURL:self.outputURL
                                                fileType:AVFileTypeQuickTimeMovie
                                                   error:&error];
    if(error) {
        if([self.delegate respondsToSelector:@selector(videoWriterError:)]) {
            [self.delegate videoWriterError:error];
        }
        return;
    }
    
    //--------------------------------------------------------------------------- setup mic capture session
    if(bMicAudio) {
        NSError * micError = nil;
        AVCaptureDevice * captureDevice = [AVCaptureDevice defaultDeviceWithMediaType: AVMediaTypeAudio];
        self.captureInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&micError];
        self.captureOutput = [[AVCaptureAudioDataOutput alloc] init];
        
        self.captureSession = [[AVCaptureSession alloc] init];
        self.captureSession.sessionPreset = AVCaptureSessionPresetLow;
        [self.captureSession addInput:self.captureInput];
        [self.captureSession addOutput:self.captureOutput];

        dispatch_queue_t queue = dispatch_queue_create("MyQueue", NULL);
            [self.captureOutput setSampleBufferDelegate:self queue:queue];
      
        [self.captureSession startRunning];
    }

    //--------------------------------------------------------------------------- adding video input.
    NSDictionary * videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                    AVVideoCodecH264, AVVideoCodecKey,
                                    [NSNumber numberWithInt:self.videoSize.width], AVVideoWidthKey,
                                    [NSNumber numberWithInt:self.videoSize.height], AVVideoHeightKey,
                                    nil];
    
    // initialized a new input for video to receive sample buffers for writing
    // passing nil for outputSettings instructs the input to pass through appended samples, doing no processing before they are written
    self.assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                    outputSettings:videoSettings];
    if ([rotation  isEqual: @"right"]) {
      [self.assetWriterVideoInput setTransform:CGAffineTransformScale(CGAffineTransformMakeRotation(M_PI/2), -1.0, -1.0)];
    }
  
    if ([rotation isEqual: @"left"]) {
      [self.assetWriterVideoInput setTransform:CGAffineTransformScale(CGAffineTransformMakeRotation(-M_PI/2), -1.0, -1.0)];
    }
  
    self.assetWriterVideoInput.expectsMediaDataInRealTime = expectsMediaDataInRealTime;
    
    // You need to use BGRA for the video in order to get realtime encoding.
    // Color-swizzling shader is used to line up glReadPixels' normal RGBA output with the movie input's BGRA.
    NSDictionary * sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                            [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                            [NSNumber numberWithInt:videoSize.width], kCVPixelBufferWidthKey,
                                                            [NSNumber numberWithInt:videoSize.height], kCVPixelBufferHeightKey,
                                                            nil];
    
    self.assetWriterInputPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.assetWriterVideoInput
                                                                                                               sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    if([self.assetWriter canAddInput:self.assetWriterVideoInput]) {
        [self.assetWriter addInput:self.assetWriterVideoInput];
    }
    
    //--------------------------------------------------------------------------- adding audio input.
    double preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
    
    AudioChannelLayout channelLayout;
    bzero(&channelLayout, sizeof(channelLayout));
    channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    
    int numOfChannels = 1;
    if(channelLayout.mChannelLayoutTag == kAudioChannelLayoutTag_Stereo) {
        numOfChannels = 2;
    }
    
    NSDictionary * audioSettings = nil;
    
    audioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                     [NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                     [NSNumber numberWithInt:numOfChannels], AVNumberOfChannelsKey,
                     [NSNumber numberWithFloat:preferredHardwareSampleRate], AVSampleRateKey,
                     [NSData dataWithBytes:&channelLayout length:sizeof(channelLayout)], AVChannelLayoutKey,
                     [NSNumber numberWithInt:64000], AVEncoderBitRateKey,
                     nil];

    self.assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                    outputSettings:audioSettings];
    self.assetWriterAudioInput.expectsMediaDataInRealTime = expectsMediaDataInRealTime;
    
    if([self.assetWriter canAddInput:self.assetWriterAudioInput]) {
        [self.assetWriter addInput:self.assetWriterAudioInput];
    }

    //--------------------------------------------------------------------------- start writing!
	[self.assetWriter startWriting];
	[self.assetWriter startSessionAtSourceTime:startTime];
    
    if(bEnableTextureCache) {
        [self initTextureCache];
    }
}

- (void)finishRecording {

    if(bWriting == NO) {
        return;
    }
    
    if(assetWriter.status == AVAssetWriterStatusCompleted ||
       assetWriter.status == AVAssetWriterStatusCancelled ||
       assetWriter.status == AVAssetWriterStatusUnknown) {
        return;
    }
    
    if(self.captureSession) {
        [self.captureSession stopRunning];
        [self.captureSession removeInput:self.captureInput];
        [self.captureSession removeOutput:self.captureOutput];
        self.captureSession = nil;
        self.captureInput = nil;
        self.captureOutput = nil;
    }
    
    bWriting = NO;
    dispatch_sync(videoWriterQueue, ^{
        [self disposeAssetWriterAndWriteFile:YES];
    });
}

- (void)cancelRecording {
    if(bWriting == NO) {
        return;
    }
    
    if(self.assetWriter.status == AVAssetWriterStatusCompleted) {
        return;
    }
    
    bWriting = NO;
    dispatch_sync(videoWriterQueue, ^{
		[self disposeAssetWriterAndWriteFile:NO];
    });
}

- (void) disposeAssetWriterAndWriteFile:(BOOL)writeFile {
	[self.assetWriterVideoInput markAsFinished];
	[self.assetWriterAudioInput markAsFinished];
	
	void (^releaseAssetWriter)(void) = ^{
		self.assetWriterVideoInput = nil;
		self.assetWriterAudioInput = nil;
		self.assetWriter = nil;
		self.assetWriterInputPixelBufferAdaptor = nil;
		[self destroyTextureCache];
        
        if(writeFile == YES) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if([self.delegate respondsToSelector:@selector(videoWriterComplete:)]) {
                    [self.delegate videoWriterComplete:self.outputURL];
                }

                if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
                    NSString * log = [NSString stringWithFormat:@"video saved! - %@", self.outputURL.description];
                    [self.delegate videoWriterLog:log];
                }
            });
            
        } else {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if([self.delegate respondsToSelector:@selector(videoWriterCancelled)]) {
                    [self.delegate videoWriterCancelled];
                }
            });
        }
	};
	
	if(writeFile) {
		[self.assetWriter finishWritingWithCompletionHandler:releaseAssetWriter];
	} else {
		[self.assetWriter cancelWriting];
		releaseAssetWriter();
	}
}

- (BOOL)isWriting {
    return bWriting;
}

//--------------------------------------------------------------------------- add frame.
- (BOOL)addFrameAtTime:(CMTime)frameTime {

    if(bWriting == NO) {
        return NO;
    }
    
    if((CMTIME_IS_INVALID(frameTime)) ||
       (CMTIME_COMPARE_INLINE(frameTime, ==, previousFrameTime)) ||
       (CMTIME_IS_INDEFINITE(frameTime))) {
        return NO;
    }
    
    if(assetWriterVideoInput.readyForMoreMediaData == NO) {
        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
            NSString * log = @"[VideoWriter addFrameAtTime] - not ready for more media data";
            [self.delegate videoWriterLog:log];
        }
        return NO;
    }

    //---------------------------------------------------------- fill pixel buffer.
    CVPixelBufferRef pixelBuffer = NULL;

    //----------------------------------------------------------
    // check if texture cache is enabled,
    // if so, use the pixel buffer from the texture cache.
    //----------------------------------------------------------
    
    if(bUseTextureCache == YES) {
        pixelBuffer = _textureCachePixelBuffer;
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    }
    
    //----------------------------------------------------------
    // if texture cache is disabled,
    // read the pixels from screen or fbo.
    // this is a much slower fallback alternative.
    //----------------------------------------------------------
    
    if(pixelBuffer == NULL) {
        CVPixelBufferPoolRef pixelBufferPool = [self.assetWriterInputPixelBufferAdaptor pixelBufferPool];
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pixelBufferPool, &pixelBuffer);
        if((pixelBuffer == NULL) || (status != kCVReturnSuccess)) {
            return NO;
        } else {
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            GLubyte * pixelBufferData = (GLubyte *)CVPixelBufferGetBaseAddress(pixelBuffer);
            glReadPixels(0, 0, self.videoSize.width, self.videoSize.height, GL_RGBA, GL_UNSIGNED_BYTE, pixelBufferData);
        }
    }
    
    //----------------------------------------------------------
    dispatch_sync(videoWriterQueue, ^{
        
        BOOL bOk = [self.assetWriterInputPixelBufferAdaptor appendPixelBuffer:pixelBuffer
                                                         withPresentationTime:frameTime];
        if(bOk == NO) {
            if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
                NSString * errorDesc = self.assetWriter.error.description;
                NSString * log = [NSString stringWithFormat:@"[VideoWriter addFrameAtTime] - error appending video samples - %@", errorDesc];
                [self.delegate videoWriterLog:log];
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        previousFrameTime = frameTime;
        
        if(bUseTextureCache == NO) {
            CVPixelBufferRelease(pixelBuffer);
        }
    });
    
    return YES;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput_
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    
    if(bWriting == NO) {
        return;
    }
    if(CMSampleBufferDataIsReady(sampleBuffer) == false) {
        NSLog( @"sample buffer is not ready. Skipping sample" );
        return;
    }
    if(self.captureOutput == captureOutput_){ //double check to make sure this is actually audio
        [self addAudio:sampleBuffer]; // this is where the audio gets sent to be recorded
    }
}

- (BOOL)addAudio:(CMSampleBufferRef)audioBuffer {
    
    if(bWriting == NO) {
        return NO;
    }
    
    if(audioBuffer == nil) {
        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
            NSString * log = @"[VideoWriter addAudio] - audioBuffer was nil.";
            [self.delegate videoWriterLog:log];
        }
        return NO;
    }
	
	if(assetWriterAudioInput.readyForMoreMediaData == NO) {
        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
            NSString * log = @"[VideoWriter addAudio] - not ready for more media data";
            [self.delegate videoWriterLog:log];
        }
        return NO;
    }
	
	CMTime newBufferTime = CMSampleBufferGetPresentationTimeStamp(audioBuffer);
	if (CMTIME_COMPARE_INLINE(newBufferTime, ==, previousAudioTime)) {
		return NO;
	}
		
	previousAudioTime = newBufferTime;
	
	// hold onto the first buffer, until we've figured out when playback truly starts (which is
	// when the second buffer arrives)
	if(bFirstAudio) {
		CMSampleBufferCreateCopy(NULL, audioBuffer, &_firstAudioBuffer);
		bFirstAudio = NO;
		return NO;
	}
	// if the incoming audio buffer has an earlier timestamp than the current "first" buffer, then
	// drop the current "first" buffer and store the new one instead
	else if(_firstAudioBuffer && CMTIME_COMPARE_INLINE(CMSampleBufferGetPresentationTimeStamp(_firstAudioBuffer), >, newBufferTime)) {
		CFRelease(_firstAudioBuffer);
		CMSampleBufferCreateCopy(NULL, audioBuffer, &_firstAudioBuffer);
		return NO;
	}

    //----------------------------------------------------------
    dispatch_sync(videoWriterQueue, ^{
		
		if(_firstAudioBuffer) {
			CMSampleBufferRef correctedFirstBuffer = [self copySampleBuffer:_firstAudioBuffer withNewTime:previousFrameTime];
			[self.assetWriterAudioInput appendSampleBuffer:correctedFirstBuffer];
			CFRelease(_firstAudioBuffer);
			CFRelease(correctedFirstBuffer);
			_firstAudioBuffer = NULL;
		}
		
		BOOL bOk = [self.assetWriterAudioInput appendSampleBuffer:audioBuffer];
        if(bOk == NO) {
            
            if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
                NSString * errorDesc = self.assetWriter.error.description;
                NSString * log = [NSString stringWithFormat:@"[VideoWriter addAudio] - error appending audio samples - %@", errorDesc];
                [self.delegate videoWriterLog:log];
            }
        }
    });
    
    return YES;
}

- (CMSampleBufferRef) copySampleBuffer:(CMSampleBufferRef)inBuffer withNewTime:(CMTime)time {
	
	CMSampleTimingInfo timingInfo;
	CMSampleBufferGetSampleTimingInfo(inBuffer, 0, &timingInfo);
	timingInfo.presentationTimeStamp = time;
	
	CMSampleBufferRef outBuffer;
	CMSampleBufferCreateCopyWithNewTiming(NULL, inBuffer, 1, &timingInfo, &outBuffer);
	return outBuffer;
}

//--------------------------------------------------------------------------- texture cache.
- (void)setEnableTextureCache:(BOOL)value {
    if(bWriting == YES) {
        
        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
            NSString * log = @"enableTextureCache can not be changed while recording.";
            [self.delegate videoWriterLog:log];
        }
    }
    bEnableTextureCache = value;
}

- (void)setExpectsMediaDataInRealTime:(BOOL)value {
    expectsMediaDataInRealTime = value;
}

- (void)initTextureCache {
    
    bTextureCacheSupported = YES;
#if TARGET_IPHONE_SIMULATOR
    bTextureCacheSupported = NO; // texture caching does not work properly on the simulator.
#endif
    bUseTextureCache = bTextureCacheSupported;
    if(bEnableTextureCache == NO) {
        bUseTextureCache = NO;
    }
    
    if(bUseTextureCache == NO) {
        return;
    }
    
    //-----------------------------------------------------------------------
    CVReturn error;
#if defined(__IPHONE_6_0)
    error = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                         NULL,
                                         context,
                                         NULL,
                                         &_textureCache);
#else
    error = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                         NULL,
                                         (__bridge void *)context,
                                         NULL,
                                         &_textureCache);
#endif
    
    if(error) {
        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
            NSString * log = [NSString stringWithFormat:@"Error at CVOpenGLESTextureCacheCreate %d", error];
            [self.delegate videoWriterLog:log];
        }
        bUseTextureCache = NO;
        return;
    }
    
    //-----------------------------------------------------------------------
    CVPixelBufferPoolRef pixelBufferPool = [self.assetWriterInputPixelBufferAdaptor pixelBufferPool];
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pixelBufferPool, &_textureCachePixelBuffer);
    if(status != kCVReturnSuccess) {
        bUseTextureCache = NO;
        return;
    }
    
    error = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,         // CFAllocatorRef allocator
                                                         _textureCache,               // CVOpenGLESTextureCacheRef textureCache
                                                         _textureCachePixelBuffer,    // CVPixelBufferRef source pixel buffer.
                                                         NULL,                        // CFDictionaryRef textureAttributes
                                                         GL_TEXTURE_2D,               // GLenum target
                                                         GL_RGBA,                     // GLint internalFormat
                                                         (int)self.videoSize.width,   // GLsizei width
                                                         (int)self.videoSize.height,  // GLsizei height
                                                         GL_BGRA,                     // GLenum format
                                                         GL_UNSIGNED_BYTE,            // GLenum type
                                                         0,                           // size_t planeIndex
                                                         &_textureRef);               // CVOpenGLESTextureRef *textureOut
    
    if(error) {
        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
            NSString * log = [NSString stringWithFormat:@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", error];
            [self.delegate videoWriterLog:log];
        }
        bUseTextureCache = NO;
        return;
    }
}

- (void)destroyTextureCache {
    
    if(_textureCache) {
        CVOpenGLESTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
    
    if(_textureRef) {
        CFRelease(_textureRef);
        _textureRef = NULL;
    }
    
    if(_textureCachePixelBuffer) {
        CVPixelBufferRelease(_textureCachePixelBuffer);
        _textureCachePixelBuffer = NULL;
    }
}

- (BOOL)isTextureCached {
    return bUseTextureCache;
}

- (unsigned int)textureCacheID {
    if(_textureRef != nil) {
        return CVOpenGLESTextureGetName(_textureRef);
    }
    return 0;
}

- (int)textureCacheTarget {
    if(_textureRef != nil) {
        return CVOpenGLESTextureGetTarget(_textureRef);
    }
    return 0;
}

//---------------------------------------------------------------------------
- (void)saveMovieToCameraRoll {
    
	ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
	[library writeVideoAtPathToSavedPhotosAlbum:self.outputURL
								completionBlock:^(NSURL *assetURL, NSError *error) {
									if (error) {
                                        if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
                                            NSString * log = [NSString stringWithFormat:@"assets library failed (%@)", error];
                                            [self.delegate videoWriterLog:log];
                                        }
									}
									else {
										[[NSFileManager defaultManager] removeItemAtURL:self.outputURL error:&error];
										if (error)
                                            if([self.delegate respondsToSelector:@selector(videoWriterLog:)]) {
                                                NSString * log = [NSString stringWithFormat:@"Couldn't remove temporary movie file \"%@\"", self.outputURL];
                                                [self.delegate videoWriterLog:log];
                                            }
									}
                                    
									self.outputURL = nil;
                  
                                    if([self.delegate respondsToSelector:@selector(videoWriterSavedToCameraRoll)]) {
                                        [self.delegate videoWriterSavedToCameraRoll];
                                    }
								}];
}

@end
