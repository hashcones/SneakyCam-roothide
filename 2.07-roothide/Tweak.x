#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <AudioToolbox/AudioServices.h>

// MARK: - Preference Identifiers
static NSString *const kDomain = @"com.autt.sneakycamprefs";
static NSString *const kPrefNotification = @"com.autt.sneakycamprefs/PreferencesChanged";

static BOOL kEnabled = YES;
static BOOL kShowStatusBarIndicator = NO;
static NSInteger kCameraPosition = 0; // 0 = Back, 1 = Front

static void loadPreferences(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    
    CFPropertyListRef valEnabled = CFPreferencesCopyAppValue((__bridge CFStringRef)@"enabled", (__bridge CFStringRef)kDomain);
    kEnabled = valEnabled ? [(__bridge id)valEnabled boolValue] : YES;
    if (valEnabled) CFRelease(valEnabled);

    CFPropertyListRef valIndicator = CFPreferencesCopyAppValue((__bridge CFStringRef)@"showStatusBarIndicator", (__bridge CFStringRef)kDomain);
    kShowStatusBarIndicator = valIndicator ? [(__bridge id)valIndicator boolValue] : NO;
    if (valIndicator) CFRelease(valIndicator);

    CFPropertyListRef valCamPos = CFPreferencesCopyAppValue((__bridge CFStringRef)@"cameraPosition", (__bridge CFStringRef)kDomain);
    kCameraPosition = valCamPos ? [(__bridge id)valCamPos integerValue] : 0;
    if (valCamPos) CFRelease(valCamPos);
}

// MARK: - Status Bar Sensor Privacy Dot Suppression
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

// MARK: - Background Capture Manager
@interface BackgroundRecorder : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) BOOL isRecording;
+ (instancetype)sharedInstance;
- (void)toggleRecording;
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
        _sessionQueue = dispatch_queue_create("com.autt.sneakycam.sessionQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)setupSessionWithCompletion:(void(^)(BOOL success))completion {
    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession) {
            if (completion) completion(YES);
            return;
        }

        self.captureSession = [[AVCaptureSession alloc] init];
        [self.captureSession beginConfiguration];

        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
            self.captureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
        } else {
            self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        }

        // Camera Input
        AVCaptureDevicePosition desiredPosition = (kCameraPosition == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                         mediaType:AVMediaTypeVideo
                                                                          position:desiredPosition];
        NSError *videoError = nil;
        AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&videoError];
        if (!videoError && [self.captureSession canAddInput:videoInput]) {
            [self.captureSession addInput:videoInput];
        } else {
            [self.captureSession commitConfiguration];
            if (completion) completion(NO);
            return;
        }

        // Audio Input
        AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        NSError *audioError = nil;
        AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioError];
        if (!audioError && [self.captureSession canAddInput:audioInput]) {
            [self.captureSession addInput:audioInput];
        }

        // Movie File Output
        self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
        if ([self.captureSession canAddOutput:self.movieOutput]) {
            [self.captureSession addOutput:self.movieOutput];
        } else {
            [self.captureSession commitConfiguration];
            if (completion) completion(NO);
            return;
        }

        [self.captureSession commitConfiguration];
        if (completion) completion(YES);
    });
}

- (void)toggleRecording {
    if (!self.isRecording) {
        [self startRecording];
    } else {
        [self stopRecording];
    }
}

- (void)startRecording {
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

            [self.movieOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
            self.isRecording = YES;

            AudioServicesPlaySystemSound(1519); // Start vibration
        });
    }];
}

- (void)stopRecording {
    dispatch_async(self.sessionQueue, ^{
        if (self.movieOutput.isRecording) {
            [self.movieOutput stopRecording];
        }
        self.isRecording = NO;
        AudioServicesPlaySystemSound(1521); // Stop vibration
    });
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
        [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
        return;
    }

    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:outputFileURL];
            } completionHandler:^(BOOL success, NSError * _Nullable saveError) {
                [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
            }];
        } else {
            [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
        }
    }];
}

@end

// MARK: - SpringBoard Volume Button Hooks
%hook SBVolumeHardwareButtonActions

- (void)volumeIncreasePress:(id)arg1 {
    if (kEnabled) {
        [[BackgroundRecorder sharedInstance] toggleRecording];
    }
    %orig(arg1);
}

%end

// MARK: - Constructor
%ctor {
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
