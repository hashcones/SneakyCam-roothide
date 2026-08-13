#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// Forward declarations
@interface SBVolumeControl : NSObject
- (void)handleVolumeButtonWithKeyType:(char)keyType down:(BOOL)isDown;
@end

// Preference helper
static NSDictionary *getPreferences() {
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sparkdev.sneakycam.plist"];
}

@interface SneakyRecorder : NSObject <AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, assign) BOOL isRecording;

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
        [self setupCaptureSession];
    }
    return self;
}

- (void)setupCaptureSession {
    NSDictionary *prefs = getPreferences();
    
    // Check if tweak is enabled
    BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!enabled) return;

    self.session = [[AVCaptureSession alloc] init];
    [self.session beginConfiguration];

    // Configure Video Quality Preset
    NSString *quality = prefs[@"VideoQuality"] ?: AVCaptureSessionPresetHigh;
    if ([self.session canSetSessionPreset:quality]) {
        self.session.sessionPreset = quality;
    }

    // Configure Front vs Back Camera
    NSInteger cameraSource = prefs[@"CameraSource"] ? [prefs[@"CameraSource"] integerValue] : 0;
    AVCaptureDevicePosition position = (cameraSource == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                       mediaType:AVMediaTypeVideo
                                                                        position:position];
    NSError *error = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];

    if (videoInput && [self.session canAddInput:videoInput]) {
        [self.session addInput:videoInput];
    }

    // Configure Outputs (Movie and Photo)
    self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
    if ([self.session canAddOutput:self.movieOutput]) {
        [self.session addOutput:self.movieOutput];
    }

    self.photoOutput = [[AVCapturePhotoOutput alloc] init];
    if ([self.session canAddOutput:self.photoOutput]) {
        [self.session addOutput:self.photoOutput];
    }

    [self.session commitConfiguration];
}

- (void)triggerCapture {
    NSDictionary *prefs = getPreferences();
    BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!enabled) return;

    // Haptic Feedback
    BOOL hapticEnabled = prefs[@"HapticFeedback"] ? [prefs[@"HapticFeedback"] boolValue] : YES;
    if (hapticEnabled) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }

    // Mode: 0 = Photo, 1 = Video
    NSInteger captureMode = prefs[@"CaptureMode"] ? [prefs[@"CaptureMode"] integerValue] : 1;

    if (captureMode == 0) {
        [self capturePhoto];
    } else {
        [self toggleVideoRecording];
    }
}

- (void)capturePhoto {
    if (!self.session.isRunning) {
        [self.session startRunning];
    }
    
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    [self.photoOutput capturePhotoWithSettings:settings delegate:self];
}

- (void)toggleVideoRecording {
    if (self.isRecording) {
        [self stopVideoRecording];
    } else {
        [self startVideoRecording];
    }
}

- (void)startVideoRecording {
    if (!self.session.isRunning) {
        [self.session startRunning];
    }
    
    NSString *fileName = [NSString stringWithFormat:@"capture_%f.mov", [[NSDate date] timeIntervalSince1970]];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
    
    [self.movieOutput startRecordingToOutputFileURL:fileURL recordingDelegate:self];
    self.isRecording = YES;
}

- (void)stopVideoRecording {
    if (self.movieOutput.isRecording) {
        [self.movieOutput stopRecording];
    }
    if (self.session.isRunning) {
        [self.session stopRunning];
    }
    self.isRecording = NO;
}

// Delegate: Video recording finished
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
    // Saved output to outputFileURL
}

// Delegate: Photo capture finished
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    // Process captured photo
}

@end

// Hook SBVolumeControl for Hardware Button Interception
%hook SBVolumeControl

- (void)handleVolumeButtonWithKeyType:(char)keyType down:(BOOL)isDown {
    if (isDown) {
        NSDictionary *prefs = getPreferences();
        BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
        
        if (enabled) {
            [[SneakyRecorder sharedInstance] triggerCapture];
        }
    }
    %orig;
}

%end