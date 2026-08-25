#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <AudioToolbox/AudioServices.h>

// MARK: - Capture State Enum
typedef NS_ENUM(NSInteger, SneakyCaptureState) {
    SneakyCaptureStateIdle = 0,
    SneakyCaptureStateStarting,
    SneakyCaptureStateRecording,
    SneakyCaptureStateStopping
};

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
static BOOL kShowStatusBarIndicator = YES;
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
    READ_BOOL(@"showStatusBarIndicator", kShowStatusBarIndicator, YES);
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

    SNEAKY_LOG(@"Preferences Loaded: Enabled=%d, CustomIndicator=%d, Mode=%ld, CamPos=%ld, Quality=%@",
               kEnabled, kShowStatusBarIndicator, (long)kCaptureMode, (long)kCameraPosition, kVideoQuality);
}

// MARK: - Custom Red Dot Indicator View
@interface SneakyCustomIndicator : NSObject
@property (nonatomic, strong) UIWindow *indicatorWindow;
@property (nonatomic, strong) UIView *dotView;
+ (instancetype)sharedInstance;
- (void)show;
- (void)hide;
@end

@implementation SneakyCustomIndicator

+ (instancetype)sharedInstance {
    static SneakyCustomIndicator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SneakyCustomIndicator alloc] init];
    });
    return instance;
}

- (void)setupWindowIfNeeded {
    if (self.indicatorWindow) return;

    CGFloat dotSize = 8.0;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGRect frame = CGRectMake(screenWidth - 28.0, 14.0, dotSize, dotSize);

    self.indicatorWindow = [[UIWindow alloc] initWithFrame:frame];
    self.indicatorWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
    self.indicatorWindow.backgroundColor = [UIColor clearColor];
    self.indicatorWindow.userInteractionEnabled = NO;
    self.indicatorWindow.hidden = YES;

    self.dotView = [[UIView alloc] initWithFrame:self.indicatorWindow.bounds];
    self.dotView.backgroundColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1.0];
    self.dotView.layer.cornerRadius = dotSize / 2.0;
    self.dotView.layer.masksToBounds = YES;
    [self.indicatorWindow addSubview:self.dotView];
}

- (void)show {
    if (!kEnabled || !kShowStatusBarIndicator) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupWindowIfNeeded];
        self.indicatorWindow.hidden = NO;
        self.dotView.alpha = 1.0;

        [UIView animateWithDuration:0.7
                              delay:0.0
                            options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.dotView.alpha = 0.25;
        } completion:nil];
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.indicatorWindow) {
            [self.dotView.layer removeAllAnimations];
            self.indicatorWindow.hidden = YES;
        }
    });
}

@end

// MARK: - Native iOS Green Privacy Dot Suppression
@interface _UIStatusBarSensorActivityView : UIView
@end

@interface _UIStatusBarSensorActivityItem : NSObject
@end

%hook _UIStatusBarSensorActivityView

- (void)setHidden:(BOOL)hidden {
    if (kEnabled) {
        %orig(YES);
    } else {
        %orig(hidden);
    }
}

- (void)setAlpha:(CGFloat)alpha {
    if (kEnabled) {
        %orig(0.0);
    } else {
        %orig(alpha);
    }
}

- (void)layoutSubviews {
    %orig;
    if (kEnabled) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

%hook _UIStatusBarSensorActivityItem

- (id)applyUpdate:(id)arg1 toDisplayItem:(id)arg2 {
    if (kEnabled) {
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

// MARK: - Background Capture Manager
@interface BackgroundRecorder : NSObject <AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) SneakyCaptureState captureState;
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
        _captureState = SneakyCaptureStateIdle;
        _sessionQueue = dispatch_queue_create("com.spark.sneakycam.sessionQueue", DISPATCH_QUEUE_SERIAL);

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionDidStartRunning:)
                                                     name:AVCaptureSessionDidStartRunningNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionRuntimeError:)
                                                     name:AVCaptureSessionRuntimeErrorNotification
                                                   object:nil];
    }
    return self;
}

- (void)sessionDidStartRunning:(NSNotification *)notification {
    SNEAKY_LOG(@"Notification: AVCaptureSession hardware is running.");
    dispatch_async(self.sessionQueue, ^{
        if (self.captureState == SneakyCaptureStateStarting) {
            [self beginFileOutput];
        }
    });
}

- (void)sessionRuntimeError:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
    SNEAKY_LOG(@"FATAL: Session runtime error: %@", error.localizedDescription);
    dispatch_async(self.sessionQueue, ^{
        [self forceResetSession];
    });
}

- (void)setupSessionWithCompletion:(void(^)(BOOL success))completion {
    if (self.captureSession) {
        if (completion) completion(YES);
        return;
    }

    SNEAKY_LOG(@"Configuring AVCaptureSession...");
    self.captureSession = [[AVCaptureSession alloc] init];
    [self.captureSession beginConfiguration];

    // 1. Audio Session
    if (kRecordAudio && kCaptureMode == 1) {
        NSError *audioSessionError = nil;
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord 
                      withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker 
                            error:&audioSessionError];
        [audioSession setActive:YES error:&audioSessionError];
    }

    // 2. Preset
    if ([self.captureSession canSetSessionPreset:kVideoQuality]) {
        self.captureSession.sessionPreset = kVideoQuality;
    } else {
        self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
    }

    // 3. Video Device
    AVCaptureDevicePosition position = (kCameraPosition == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                     mediaType:AVMediaTypeVideo
                                                                      position:position];
    if (!videoDevice) {
        videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }

    if (!videoDevice) {
        SNEAKY_LOG(@"ERROR: No video device found.");
        [self.captureSession commitConfiguration];
        if (completion) completion(NO);
        return;
    }

    NSError *videoError = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&videoError];
    if (videoError || !videoInput || ![self.captureSession canAddInput:videoInput]) {
        SNEAKY_LOG(@"ERROR: Cannot add video input: %@", videoError.localizedDescription);
        [self.captureSession commitConfiguration];
        if (completion) completion(NO);
        return;
    }
    [self.captureSession addInput:videoInput];

    // 4. Audio Device
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

    // 5. Outputs
    if (kCaptureMode == 0) {
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        if ([self.captureSession canAddOutput:self.photoOutput]) {
            [self.captureSession addOutput:self.photoOutput];
        }
    } else {
        self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
        if ([self.captureSession canAddOutput:self.movieOutput]) {
            [self.captureSession addOutput:self.movieOutput];
            
            AVCaptureConnection *videoConn = [self.movieOutput connectionWithMediaType:AVMediaTypeVideo];
            if (videoConn.isVideoOrientationSupported) {
                videoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
        }
    }

    [self.captureSession commitConfiguration];
    SNEAKY_LOG(@"AVCaptureSession successfully configured.");
    if (completion) completion(YES);
}

// MARK: - Synchronized Trigger Handling
- (void)handleTrigger {
    dispatch_async(self.sessionQueue, ^{
        if (kCaptureMode == 0) {
            [self executePhotoCapture];
        } else {
            [self executeVideoToggle];
        }
    });
}

- (void)executeVideoToggle {
    SNEAKY_LOG(@"Video toggle evaluated. Current state: %ld", (long)self.captureState);

    if (self.captureState == SneakyCaptureStateStarting || 
        self.captureState == SneakyCaptureStateRecording || 
        (self.movieOutput && self.movieOutput.isRecording) ||
        (self.captureSession && self.captureSession.isRunning)) {
        
        [self stopVideoRecording];
    } else {
        [self startVideoRecording];
    }
}

- (void)startVideoRecording {
    self.captureState = SneakyCaptureStateStarting;
    SNEAKY_LOG(@"Starting video capture sequence...");

    [self setupSessionWithCompletion:^(BOOL success) {
        if (!success) {
            SNEAKY_LOG(@"ERROR: Setup failed. Resetting state to idle.");
            self.captureState = SneakyCaptureStateIdle;
            return;
        }

        dispatch_async(self.sessionQueue, ^{
            if (!self.captureSession.isRunning) {
                SNEAKY_LOG(@"Powering on camera sensor...");
                [self.captureSession startRunning];
            } else {
                [self beginFileOutput];
            }
        });
    }];
}

- (void)beginFileOutput {
    if (self.captureState != SneakyCaptureStateStarting && self.captureState != SneakyCaptureStateRecording) {
        SNEAKY_LOG(@"Aborting beginFileOutput (state is not starting/recording).");
        return;
    }

    NSString *filePath = [NSString stringWithFormat:@"/var/mobile/Documents/sneaky_%lld.mov", (long long)[[NSDate date] timeIntervalSince1970]];
    NSURL *outputURL = [NSURL fileURLWithPath:filePath];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    SNEAKY_LOG(@"Writing video frames to: %@", filePath);
    [self.movieOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
    self.captureState = SneakyCaptureStateRecording;

    [[SneakyCustomIndicator sharedInstance] show];

    if (kEnableHaptics) {
        AudioServicesPlaySystemSound(1519);
    }
}

- (void)stopVideoRecording {
    self.captureState = SneakyCaptureStateStopping;
    SNEAKY_LOG(@"Executing video teardown...");

    if (self.movieOutput.isRecording) {
        [self.movieOutput stopRecording];
    }

    if (self.captureSession.isRunning) {
        [self.captureSession stopRunning];
    }

    self.captureState = SneakyCaptureStateIdle;

    [[SneakyCustomIndicator sharedInstance] hide];

    if (kEnableHaptics) {
        AudioServicesPlaySystemSound(1521);
    }
}

- (void)forceResetSession {
    if (self.movieOutput.isRecording) {
        [self.movieOutput stopRecording];
    }
    if (self.captureSession.isRunning) {
        [self.captureSession stopRunning];
    }
    self.captureState = SneakyCaptureStateIdle;
    [[SneakyCustomIndicator sharedInstance] hide];
}

- (void)executePhotoCapture {
    [self setupSessionWithCompletion:^(BOOL success) {
        if (!success) return;

        dispatch_async(self.sessionQueue, ^{
            if (!self.captureSession.isRunning) {
                [self.captureSession startRunning];
            }

            [[SneakyCustomIndicator sharedInstance] show];

            AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
            [self.photoOutput capturePhotoWithSettings:settings delegate:self];

            if (kEnableHaptics) {
                AudioServicesPlaySystemSound(1519);
            }
        });
    }];
}

// MARK: - Delegates
- (void)captureOutput:(AVCaptureFileOutput *)output 
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL 
      fromConnections:(NSArray<AVCaptureConnection *> *)connections 
                error:(NSError *)error {
    
    SNEAKY_LOG(@"Recording finished callback. Error: %@", error ? error.localizedDescription : @"None");

    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
        self.captureState = SneakyCaptureStateIdle;
    });

    [[SneakyCustomIndicator sharedInstance] hide];

    if (error && ![[error.userInfo objectForKey:AVErrorRecordingSuccessfullyFinishedKey] boolValue]) {
        SNEAKY_LOG(@"ERROR: Video recording failed. Removing temporary file.");
        [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
        return;
    }

    if (kSaveToPhotos) {
        NSString *path = [outputFileURL path];
        if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path)) {
            UISaveVideoAtPathToSavedPhotosAlbum(path, nil, nil, nil);
            SNEAKY_LOG(@"SUCCESS: Video saved to Camera Roll.");
        }
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output 
didFinishProcessingPhoto:(AVCapturePhoto *)photo 
                error:(NSError *)error {
    
    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
    });

    [[SneakyCustomIndicator sharedInstance] hide];

    if (error) {
        SNEAKY_LOG(@"Photo error: %@", error.localizedDescription);
        return;
    }

    NSData *imageData = [photo fileDataRepresentation];
    if (imageData && kSaveToPhotos) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    [[PHAssetCreationRequest creationRequestForAsset] addResourceWithType:PHAssetResourceTypePhoto data:imageData options:nil];
                } completionHandler:nil];
            }
        }];
    }
}

@end

// MARK: - SpringBoard Hardware Button Hook
%hook SpringBoard

- (void)_handlePhysicalButtonEvent:(UIPressesEvent *)event {
    if (kEnabled) {
        for (UIPress *press in event.allPresses) {
            if (press.phase == UIPressPhaseBegan) {
                if (press.type == 102 && (kTriggerMethod == 0 || kTriggerMethod == 2)) {
                    SNEAKY_LOG(@"Trigger: Volume Up (102)");
                    [[BackgroundRecorder sharedInstance] handleTrigger];
                    if (kHideVolumeHUD) return;
                } else if (press.type == 103 && (kTriggerMethod == 1 || kTriggerMethod == 2)) {
                    SNEAKY_LOG(@"Trigger: Volume Down (103)");
                    [[BackgroundRecorder sharedInstance] handleTrigger];
                    if (kHideVolumeHUD) return;
                }
            }
        }
    }
    %orig;
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
