#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Photos/Photos.h>

@interface SBVolumeControl : NSObject
- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down;
@end

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

// Indicator Dot Window
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

// Core Media Capture Controller
@interface SneakyRecorder : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterInput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) NSURL *currentOutputURL;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL shouldWriteFrames;
@property (nonatomic, assign) BOOL isSessionStarted;

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
        [self setupCaptureSession];
    }
    return self;
}

- (void)setupCaptureSession {
    dispatch_async(self.sessionQueue, ^{
        SneakyLog(@"Configuring AVCaptureSession for VideoDataOutput...");
        self.session = [[AVCaptureSession alloc] init];
        [self.session beginConfiguration];

        self.session.sessionPreset = AVCaptureSessionPreset1280x720;

        NSDictionary *prefs = getPreferences();
        NSInteger cameraSource = prefs[@"CameraSource"] ? [prefs[@"CameraSource"] integerValue] : 0;
        AVCaptureDevicePosition position = (cameraSource == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;

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
                SneakyLog(@"Camera device connected: %@", videoDevice.localizedName);
            }
        }

        // Setup VideoDataOutput
        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoDataOutput.alwaysDiscardsLateVideoFrames = YES;
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoQueue];

        if ([self.session canAddOutput:self.videoDataOutput]) {
            [self.session addOutput:self.videoDataOutput];
            SneakyLog(@"VideoDataOutput attached successfully.");
        }

        [self.session commitConfiguration];
    });
}

- (void)triggerCapture {
    NSDictionary *prefs = getPreferences();
    BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!enabled) return;

    if (prefs[@"HapticFeedback"] ? [prefs[@"HapticFeedback"] boolValue] : YES) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }

    [self toggleVideoRecording];
}

- (void)toggleVideoRecording {
    if (self.isRecording) {
        SneakyLog(@"Stopping video recording...");
        self.shouldWriteFrames = NO;
        self.isRecording = NO;
        [[SneakyDotIndicator sharedInstance] hide];

        dispatch_async(self.videoQueue, ^{
            if (self.assetWriter && self.assetWriter.status == AVAssetWriterStatusWriting) {
                [self.assetWriterInput markAsFinished];
                [self.assetWriter finishWritingWithCompletionHandler:^{
                    SneakyLog(@"AVAssetWriter finished writing. File: %@", self.currentOutputURL.path);
                    
                    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:self.currentOutputURL.path];
                    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:self.currentOutputURL.path error:nil] fileSize];
                    SneakyLog(@"Video on disk: exists=%d, size=%llu bytes", exists, size);

                    if (exists && size > 0) {
                        NSDictionary *prefs = getPreferences();
                        NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;
                        if (saveLocation == 0 && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(self.currentOutputURL.path)) {
                            UISaveVideoAtPathToSavedPhotosAlbum(self.currentOutputURL.path, nil, nil, nil);
                            SneakyLog(@"Exported video to Camera Roll.");
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
        SneakyLog(@"Starting video recording via AVAssetWriter...");
        NSString *dir = @"/var/mobile/Documents/SneakyCam";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *fileName = [NSString stringWithFormat:@"SneakyCam_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
        self.currentOutputURL = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:fileName]];
        [[NSFileManager defaultManager] removeItemAtURL:self.currentOutputURL error:nil];

        NSError *err = nil;
        self.assetWriter = [AVAssetWriter assetWriterWithURL:self.currentOutputURL fileType:AVFileTypeMPEG4 error:&err];

        NSDictionary *outputSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @1280,
            AVVideoHeightKey: @720
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

        dispatch_async(self.sessionQueue, ^{
            if (!self.session.isRunning) {
                [self.session startRunning];
            }
        });

        NSDictionary *prefs = getPreferences();
        if (prefs[@"ShowIndicatorDot"] ? [prefs[@"ShowIndicatorDot"] boolValue] : YES) {
            [[SneakyDotIndicator sharedInstance] show];
        }
        SneakyLog(@"AVAssetWriter initialized for output: %@", self.currentOutputURL.path);
    }
}

// AVCaptureVideoDataOutput SampleBuffer Delegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!self.shouldWriteFrames || !self.assetWriter || self.assetWriter.status != AVAssetWriterStatusWriting) {
        return;
    }

    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    if (!self.isSessionStarted) {
        [self.assetWriter startSessionAtSourceTime:timestamp];
        self.isSessionStarted = YES;
        SneakyLog(@"AVAssetWriter session started at timestamp %lld", timestamp.value);
    }

    if (self.assetWriterInput.isReadyForMoreMediaData) {
        [self.assetWriterInput appendSampleBuffer:sampleBuffer];
    }
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