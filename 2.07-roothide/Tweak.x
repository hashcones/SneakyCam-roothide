#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <AudioToolbox/AudioServices.h>

// MARK: - Logging Implementation
static NSString *const kLogFilePath = @"/var/mobile/Documents/SneakyCam.log";

static void SNEAKY_LOG(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[SneakyCam] %@", message);

    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    });

    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    NSData *logData = [logEntry dataUsingEncoding:NSUTF8StringEncoding];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:kLogFilePath]) {
        [fileManager createFileAtPath:kLogFilePath contents:logData attributes:nil];
    } else {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:kLogFilePath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:logData];
            [fileHandle closeFile];
        }
    }
}

// MARK: - Preferences
static NSString *const kDomain = @"com.spark.sneakycamprefs";
static NSString *const kPrefNotification = @"com.spark.sneakycamprefs/PreferencesChanged";

static BOOL kEnabled = YES;
static BOOL kShowStatusBarIndicator = NO;
static BOOL kMuteShutterSound = YES;
static BOOL kRecordAudio = YES;
static BOOL kEnableHaptics = YES;
static BOOL kHideVolumeHUD = YES;
static BOOL kSaveToPhotos = YES;
static NSInteger kCaptureMode = 1;     // 0 = Photo, 1 = Video
static NSInteger kCameraPosition = 0;  // 0 = Back, 1 = Front
static NSInteger kTriggerMethod = 0;   // 0 = Volume Up, 1 = Volume Down, 2 = Both
static NSString *kVideoQuality = @"AVCaptureSessionPreset1920x1080";

static void loadPreferences(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);

    #define READ_BOOL(key, var, defaultVal) { \
        CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain); \
        var = val ? [(__bridge id)val boolValue] : defaultVal; \
        if (val) CFRelease(val); \
    }
    #define READ_INT(key, var, defaultVal) { \
        CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain); \
        var = val ? [(__bridge id)val integerValue] : defaultVal; \
        if (val) CFRelease(val); \
    }

    READ_BOOL(@"enabled", kEnabled, YES);
    READ_BOOL(@"showStatusBarIndicator", kShowStatusBarIndicator, NO);
    READ_BOOL(@"muteShutterSound", kMuteShutterSound, YES);
    READ_BOOL(@"recordAudio", kRecordAudio, YES);
    READ_BOOL(@"enableHaptics", kEnableHaptics, YES);
    READ_BOOL(@"hideVolumeHUD", kHideVolumeHUD, YES);
    READ_BOOL(@"saveToPhotos", kSaveToPhotos, YES);
    READ_INT(@"captureMode", kCaptureMode, 1);
    READ_INT(@"cameraPosition", kCameraPosition, 0);
    READ_INT(@"triggerMethod", kTriggerMethod, 0);

    CFPropertyListRef valQuality = CFPreferencesCopyAppValue((__bridge CFStringRef)@"videoQuality", (__bridge CFStringRef)kDomain);
    if (valQuality) {
        kVideoQuality = [(__bridge id)valQuality copy];
        CFRelease(valQuality);
    } else {
        kVideoQuality = @"AVCaptureSessionPreset1920x1080";
    }

    SNEAKY_LOG(@"Preferences Loaded: Enabled=%d, Indicator=%d, ShutterMuted=%d, Audio=%d, Mode=%ld, CamPos=%ld, Trigger=%ld, Quality=%@",
               kEnabled, kShowStatusBarIndicator, kMuteShutterSound, kRecordAudio, (long)kCaptureMode, (long)kCameraPosition, (long)kTriggerMethod, kVideoQuality);
}

// MARK: - Status Bar Privacy Dot Suppression
@interface _UIStatusBarSensorActivityView : UIView
@end

@interface _UIStatusBarSensorActivityItem : NSObject
@end

%hook _UIStatusBarSensorActivityView

- (void)setHidden:(BOOL)hidden {
    if (kEnabled && !kShowStatusBarIndicator) {
        %orig(YES);
    } else {
        %orig(hidden);
    }
}

- (void)setAlpha:(CGFloat)alpha {
    if (kEnabled && !kShowStatusBarIndicator) {
        %orig(0.0);
    } else {
        %orig(alpha);
    }
}

- (void)layoutSubviews {
    %orig;
    if (kEnabled && !kShowStatusBarIndicator) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

%hook _UIStatusBarSensorActivityItem

- (id)applyUpdate:(id)arg1 toDisplayItem:(id)arg2 {
    if (kEnabled && !kShowStatusBarIndicator) {
        return nil;
    }
    return %orig(arg1, arg2);
}

%end

// MARK: - Celestial Audio Shutter Mute Hook
%hook AVSystemController

- (BOOL)canBeSilencedByVolumeMuteKey {
    if (kEnabled && kMuteShutterSound) {
        return YES;
    }
    return %orig;
}

%end

// MARK: - Capture Manager
@interface BackgroundRecorder : NSObject <AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) BOOL isRecording;
+ (instancetype)sharedInstance;
- (void)handleTrigger;
@end

@implementation BackgroundRecorder

+ (instancetype)sharedInstance {
    static BackgroundRecorder *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BackgroundRecorder alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRecording = NO;
        _sessionQueue = dispatch_queue_create("com.spark.sneakycam.sessionQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)setupSessionWithCompletion:(void(^)(BOOL success))completion {
    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession) {
            if (completion) completion(YES);
            return;
        }

        SNEAKY_LOG(@"Initializing AVCaptureSession...");
        self.captureSession = [[AVCaptureSession alloc] init];
        [self.captureSession beginConfiguration];

        // Set Preset
        if ([self.captureSession canSetSessionPreset:kVideoQuality]) {
            self.captureSession.sessionPreset = kVideoQuality;
        } else {
            self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        }

        // Video Device Input
        AVCaptureDevicePosition position = (kCameraPosition == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                         mediaType:AVMediaTypeVideo
                                                                          position:position];
        if (!videoDevice) {
            videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        }

        if (!videoDevice) {
            SNEAKY_LOG(@"ERROR: Video capture device not available.");
            [self.captureSession commitConfiguration];
            if (completion) completion(NO);
            return;
        }

        NSError *videoError = nil;
        AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&videoError];
        if (videoError || !videoInput || ![self.captureSession canAddInput:videoInput]) {
            SNEAKY_LOG(@"ERROR: Failed to add video input: %@", videoError.localizedDescription);
            [self.captureSession commitConfiguration];
            if (completion) completion(NO);
            return;
        }
        [self.captureSession addInput:videoInput];

        // Audio Device Input
        if (kRecordAudio && kCaptureMode == 1) {
            AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            if (audioDevice) {
                NSError *audioError = nil;
                AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioError];
                if (!audioError && audioInput && [self.captureSession canAddInput:audioInput]) {
                    [self.captureSession addInput:audioInput];
                }
            }
        }

        // Outputs
        if (kCaptureMode == 0) { // Photo Mode
            self.photoOutput = [[AVCapturePhotoOutput alloc] init];
            if ([self.captureSession canAddOutput:self.photoOutput]) {
                [self.captureSession addOutput:self.photoOutput];
            }
        } else { // Video Mode
            self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
            if ([self.captureSession canAddOutput:self.movieOutput]) {
                [self.captureSession addOutput:self.movieOutput];
            }
        }

        [self.captureSession commitConfiguration];
        SNEAKY_LOG(@"AVCaptureSession setup complete.");
        if (completion) completion(YES);
    });
}

- (void)handleTrigger {
    if (kCaptureMode == 0) {
        [self captureStillPhoto];
    } else {
        [self toggleVideoRecording];
    }
}

- (void)captureStillPhoto {
    [self setupSessionWithCompletion:^(BOOL success) {
        if (!success) return;

        dispatch_async(self.sessionQueue, ^{
            if (!self.captureSession.isRunning) {
                [self.captureSession startRunning];
            }

            AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
            [self.photoOutput capturePhotoWithSettings:settings delegate:self];

            if (kEnableHaptics) {
                AudioServicesPlaySystemSound(1519);
            }
        });
    }];
}

- (void)toggleVideoRecording {
    if (!self.isRecording) {
        [self startVideoRecording];
    } else {
        [self stopVideoRecording];
    }
}

- (void)startVideoRecording {
    [self setupSessionWithCompletion:^(BOOL success) {
        if (!success) return;

        dispatch_async(self.sessionQueue, ^{
            if (!self.captureSession.isRunning) {
                [self.captureSession startRunning];
            }

            NSString *fileName = [NSString stringWithFormat:@"sneakycam_%lld.mov", (long long)[[NSDate date] timeIntervalSince1970]];
            NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
            NSURL *outputURL = [NSURL fileURLWithPath:filePath];

            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

            SNEAKY_LOG(@"Recording started -> %@", filePath);
            [self.movieOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
            self.isRecording = YES;

            if (kEnableHaptics) {
                AudioServicesPlaySystemSound(1519);
            }
        });
    }];
}

- (void)stopVideoRecording {
    dispatch_async(self.sessionQueue, ^{
        SNEAKY_LOG(@"Recording stopping...");
        if (self.movieOutput.isRecording) {
            [self.movieOutput stopRecording];
        }
        self.isRecording = NO;

        if (kEnableHaptics) {
            AudioServicesPlaySystemSound(1521);
        }
    });
}

// MARK: - AVCapturePhotoCaptureDelegate
- (void)captureOutput:(AVCapturePhotoOutput *)output 
didFinishProcessingPhoto:(AVCapturePhoto *)photo 
                error:(NSError *)error {
    
    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
    });

    if (error) {
        SNEAKY_LOG(@"ERROR: Photo capture failed: %@", error.localizedDescription);
        return;
    }

    NSData *imageData = [photo fileDataRepresentation];
    if (imageData && kSaveToPhotos) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    [[PHAssetCreationRequest creationRequestForAsset] addResourceWithType:PHAssetResourceTypePhoto data:imageData options:nil];
                } completionHandler:^(BOOL success, NSError * _Nullable saveError) {
                    SNEAKY_LOG(@"Photo saved to Camera Roll (Success: %d)", success);
                }];
            }
        }];
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
- (void)captureOutput:(AVCaptureFileOutput *)output 
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL 
      fromConnections:(NSArray<AVCaptureConnection *> *)connections 
                error:(NSError *)error {
    
    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
    });

    if (error && ![[error.userInfo objectForKey:AVErrorRecordingSuccessfullyFinishedKey] boolValue]) {
        SNEAKY_LOG(@"ERROR: Video recording error: %@", error.localizedDescription);
        [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
        return;
    }

    if (kSaveToPhotos) {
        NSString *path = [outputFileURL path];
        if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path)) {
            UISaveVideoAtPathToSavedPhotosAlbum(path, nil, nil, nil);
            SNEAKY_LOG(@"Video saved to Camera Roll.");
        }
    }
}

@end

// MARK: - SpringBoard Volume Control Hooks
%hook SBVolumeControl

- (void)volumeIncreasePress:(BOOL)down {
    if (kEnabled && down && (kTriggerMethod == 0 || kTriggerMethod == 2)) {
        SNEAKY_LOG(@"Trigger activated via Volume Up.");
        [[BackgroundRecorder sharedInstance] handleTrigger];
        if (kHideVolumeHUD) return;
    }
    %orig(down);
}

- (void)volumeDecreasePress:(BOOL)down {
    if (kEnabled && down && (kTriggerMethod == 1 || kTriggerMethod == 2)) {
        SNEAKY_LOG(@"Trigger activated via Volume Down.");
        [[BackgroundRecorder sharedInstance] handleTrigger];
        if (kHideVolumeHUD) return;
    }
    %orig(down);
}

%end

// MARK: - Constructor
%ctor {
    SNEAKY_LOG(@"=== SneakyCam Loaded into %@ (PID: %d) ===", 
               [NSProcessInfo processInfo].processName, 
               [[NSProcessInfo processInfo] processIdentifier]);
    loadPreferences();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)loadPreferences,
        (__bridge CFStringRef)kPrefNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
