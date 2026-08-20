#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Photos/Photos.h>

@interface SBVolumeControl : NSObject
- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down;
@end

// Live On-Device Logger (/var/mobile/Documents/sneakycam.log)
static void SneakyLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SneakyCam] %@", msg);

    NSString *logDir = @"/var/mobile/Documents";
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *logPath = [logDir stringByAppendingPathComponent:@"sneakycam.log"];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!handle) {
        [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [handle seekToEndOfFile];
        [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}

static NSDictionary *getPreferences() {
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sparkdev.sneakycam.plist"];
}

// Indicator Dot Window + Frame Pipeline Activator
@interface SneakyDotIndicator : NSObject
@property (nonatomic, strong) UIWindow *dotWindow;
@property (nonatomic, strong) UIView *dotView;
+ (instancetype)sharedInstance;
- (void)show;
- (void)hide;
@end

@implementation SneakyDotIndicator
+ (instancetype)sharedInstance {
    static SneakyDotIndicator *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SneakyDotIndicator alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            self.dotWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screenWidth - 24, 12, 10, 10)];
            self.dotWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
            self.dotWindow.backgroundColor = [UIColor clearColor];
            self.dotWindow.userInteractionEnabled = NO;

            self.dotView = [[UIView alloc] initWithFrame:self.dotWindow.bounds];
            self.dotView.backgroundColor = [UIColor systemRedColor];
            self.dotView.layer.cornerRadius = 5.0;
            self.dotView.clipsToBounds = YES;
            [self.dotWindow addSubview:self.dotView];

            self.dotWindow.hidden = YES;
        });
    }
    return self;
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dotWindow.hidden = NO;
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dotWindow.hidden = YES;
    });
}
@end

// Core Media Capture Engine
@interface SneakyRecorder : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterInput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) NSURL *currentOutputURL;
@property (nonatomic, assign) NSInteger videoWidth;
@property (nonatomic, assign) NSInteger videoHeight;
@property (nonatomic, assign) NSInteger currentMode;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL shouldWriteFrames;
@property (nonatomic, assign) BOOL isSessionStarted;
@property (nonatomic, assign) NSInteger frameCount;

+ (instancetype)sharedInstance;
- (void)triggerCapture;
@end

@implementation SneakyRecorder

+ (instancetype)sharedInstance {
    static SneakyRecorder *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SneakyRecorder alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        self.sessionQueue = dispatch_queue_create("com.sparkdev.sneakycam.sessionQueue", DISPATCH_QUEUE_SERIAL);
        self.videoQueue = dispatch_queue_create("com.sparkdev.sneakycam.videoQueue", DISPATCH_QUEUE_SERIAL);
        self.currentMode = -1;
    }
    return self;
}

- (void)configureSessionForMode:(NSInteger)mode {
    if (!self.session) {
        self.session = [[AVCaptureSession alloc] init];
    }

    [self.session beginConfiguration];

    // Remove existing inputs/outputs
    for (AVCaptureInput *input in [self.session.inputs copy]) {
        [self.session removeInput:input];
    }
    for (AVCaptureOutput *output in [self.session.outputs copy]) {
        [self.session removeOutput:output];
    }

    NSDictionary *prefs = getPreferences();
    NSInteger cameraSource = prefs[@"CameraSource"] ? [prefs[@"CameraSource"] integerValue] : 0;
    AVCaptureDevicePosition position = (cameraSource == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;

    // Attach Camera Device
    AVCaptureDevice *videoDevice = nil;
    if (@available(iOS 10.0, *)) {
        AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:position];
        videoDevice = discovery.devices.firstObject;
    }
    if (!videoDevice) {
        videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }

    if (videoDevice) {
        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&err];
        if (input && [self.session canAddInput:input]) {
            [self.session addInput:input];
            SneakyLog(@"Camera attached: %@", videoDevice.localizedName);
        }
    }

    if (mode == 0) {
        // PHOTO MODE
        if ([self.session canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
            self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        }
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        if ([self.session canAddOutput:self.photoOutput]) {
            [self.session addOutput:self.photoOutput];
        }
        SneakyLog(@"Configured for PHOTO mode.");
    } else {
        // VIDEO MODE (iPhone 7 4K / 1080p / 720p)
        NSString *requestedPreset = prefs[@"VideoQuality"] ?: AVCaptureSessionPreset3840x2160;

        if (position == AVCaptureDevicePositionBack && [requestedPreset isEqualToString:AVCaptureSessionPreset3840x2160]) {
            if ([self.session canSetSessionPreset:AVCaptureSessionPreset3840x2160]) {
                self.session.sessionPreset = AVCaptureSessionPreset3840x2160;
                self.videoWidth = 3840;
                self.videoHeight = 2160;
                SneakyLog(@"Active Preset: 4K UHD (3840x2160 @ 30fps)");
            }
        } else if ([requestedPreset isEqualToString:AVCaptureSessionPreset1920x1080] || (position == AVCaptureDevicePositionFront && [requestedPreset isEqualToString:AVCaptureSessionPreset3840x2160])) {
            if ([self.session canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
                self.session.sessionPreset = AVCaptureSessionPreset1920x1080;
                self.videoWidth = 1920;
                self.videoHeight = 1080;
                SneakyLog(@"Active Preset: Full HD (1920x1080)");
            }
        } else {
            self.session.sessionPreset = AVCaptureSessionPreset1280x720;
            self.videoWidth = 1280;
            self.videoHeight = 720;
            SneakyLog(@"Active Preset: HD (1280x720)");
        }

        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoDataOutput.alwaysDiscardsLateVideoFrames = YES;
        self.videoDataOutput.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoQueue];

        if ([self.session canAddOutput:self.videoDataOutput]) {
            [self.session addOutput:self.videoDataOutput];
            SneakyLog(@"VideoDataOutput attached with BGRA format.");
        }
    }

    [self.session commitConfiguration];
    self.currentMode = mode;
}

- (void)triggerCapture {
    NSDictionary *prefs = getPreferences();
    BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!enabled) return;

    if (prefs[@"HapticFeedback"] ? [prefs[@"HapticFeedback"] boolValue] : YES) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }

    NSInteger captureMode = prefs[@"CaptureMode"] ? [prefs[@"CaptureMode"] integerValue] : 1;
    if (captureMode == 0) {
        [self capturePhoto];
    } else {
        [self toggleVideoRecording];
    }
}

- (void)capturePhoto {
    dispatch_async(self.sessionQueue, ^{
        [self configureSessionForMode:0];

        if (!self.session.isRunning) {
            [self.session startRunning];
            SneakyLog(@"Photo session running.");
        }

        [NSThread sleepForTimeInterval:0.35];

        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
        [self.photoOutput capturePhotoWithSettings:settings delegate:self];
        SneakyLog(@"Photo capture dispatched.");
    });
}

- (void)toggleVideoRecording {
    if (self.isRecording) {
        SneakyLog(@"Stopping recording. Total frames received: %ld", (long)self.frameCount);
        self.shouldWriteFrames = NO;
        self.isRecording = NO;
        [[SneakyDotIndicator sharedInstance] hide];

        dispatch_async(self.videoQueue, ^{
            if (self.assetWriter) {
                [self.assetWriterInput markAsFinished];
                [self.assetWriter finishWritingWithCompletionHandler:^{
                    SneakyLog(@"AVAssetWriter finishWriting complete. Status: %ld", (long)self.assetWriter.status);

                    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:self.currentOutputURL.path];
                    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:self.currentOutputURL.path error:nil] fileSize];
                    SneakyLog(@"Encoded File: %@ (Size: %llu bytes)", self.currentOutputURL.path, size);

                    if (exists && size > 0) {
                        NSDictionary *prefs = getPreferences();
                        NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;

                        if (saveLocation == 0) {
                            // Save to Photos and clean up working file
                            SneakyLog(@"[Camera Roll Mode] Exporting video to Photos App...");
                            if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(self.currentOutputURL.path)) {
                                UISaveVideoAtPathToSavedPhotosAlbum(self.currentOutputURL.path, self, @selector(video:didFinishSavingWithError:contextInfo:), nil);
                            }
                        } else {
                            // Leave directly in Documents folder
                            SneakyLog(@"[Documents Mode] Video saved to: %@", self.currentOutputURL.path);
                        }
                    }

                    self.assetWriter = nil;
                    self.assetWriterInput = nil;
                    self.isSessionStarted = NO;

                    dispatch_async(self.sessionQueue, ^{
                        if (self.session.isRunning) {
                            [self.session stopRunning];
                            SneakyLog(@"Capture session stopped.");
                        }
                    });
                }];
            }
        });
    } else {
        SneakyLog(@"Starting video recording...");
        self.frameCount = 0;

        dispatch_async(self.sessionQueue, ^{
            [self configureSessionForMode:1];

            if (!self.session.isRunning) {
                [self.session startRunning];
                SneakyLog(@"Camera session running.");
            }

            NSString *dir = @"/var/mobile/Documents/SneakyCam";
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *fileName = [NSString stringWithFormat:@"SneakyCam_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
            self.currentOutputURL = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:fileName]];
            [[NSFileManager defaultManager] removeItemAtURL:self.currentOutputURL error:nil];

            NSError *err = nil;
            self.assetWriter = [AVAssetWriter assetWriterWithURL:self.currentOutputURL fileType:AVFileTypeMPEG4 error:&err];

            NSDictionary *outputSettings = @{
                AVVideoCodecKey: AVVideoCodecTypeH264,
                AVVideoWidthKey: @(self.videoWidth > 0 ? self.videoWidth : 1920),
                AVVideoHeightKey: @(self.videoHeight > 0 ? self.videoHeight : 1080)
            };

            self.assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
            self.assetWriterInput.expectsMediaDataInRealTime = YES;

            if ([self.assetWriter canAddInput:self.assetWriterInput]) {
                [self.assetWriter addInput:self.assetWriterInput];
            }

            [self.assetWriter startWriting];
            self.isSessionStarted = NO;
            self.shouldWriteFrames = YES;
            self.isRecording = YES;

            dispatch_async(dispatch_get_main_queue(), ^{
                NSDictionary *prefs = getPreferences();
                if (prefs[@"ShowIndicatorDot"] ? [prefs[@"ShowIndicatorDot"] boolValue] : YES) {
                    [[SneakyDotIndicator sharedInstance] show];
                }
            });
        });
    }
}

// Frame Processing Callback
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!self.shouldWriteFrames || !self.assetWriter) {
        return;
    }

    self.frameCount++;
    if (self.frameCount <= 3) {
        SneakyLog(@"Received frame #%ld (%ldx%ld)", (long)self.frameCount, (long)self.videoWidth, (long)self.videoHeight);
    }

    if (self.assetWriter.status != AVAssetWriterStatusWriting) {
        return;
    }

    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    if (!self.isSessionStarted) {
        [self.assetWriter startSessionAtSourceTime:timestamp];
        self.isSessionStarted = YES;
        SneakyLog(@"Writer session started at: %lld", timestamp.value);
    }

    if (self.assetWriterInput.isReadyForMoreMediaData) {
        [self.assetWriterInput appendSampleBuffer:sampleBuffer];
    }
}

// Photos Video Export Callback
- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        SneakyLog(@"Photos Album export error: %@", error.localizedDescription);
    } else {
        SneakyLog(@"Saved to Photos Camera Roll. Removing working file.");
        [[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
    }
}

// Photo Capture Callback
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (error) {
        SneakyLog(@"Photo Error: %@", error.localizedDescription);
        return;
    }

    NSData *data = [photo fileDataRepresentation];
    if (!data) return;

    UIImage *image = [UIImage imageWithData:data];
    NSDictionary *prefs = getPreferences();
    NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;

    NSString *dir = @"/var/mobile/Documents/SneakyCam";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"SneakyCam_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
    [data writeToFile:dest atomically:YES];

    if (saveLocation == 0 && image) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        SneakyLog(@"Photo exported to Photos Camera Roll.");
    } else {
        SneakyLog(@"Photo saved to Documents: %@", dest);
    }

    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
            SneakyLog(@"Photo session stopped.");
        }
    });
}

@end

// Hook Volume Buttons
%hook SBVolumeControl

- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down {
    if (down) {
        [[SneakyRecorder sharedInstance] triggerCapture];
    }
    %orig;
}

%end