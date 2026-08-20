#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Photos/Photos.h>

// Forward declarations
@interface SBVolumeControl : NSObject
- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down;
@end

static NSDictionary *getPreferences() {
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sparkdev.sneakycam.plist"];
}

// Visual Indicator Dot Window
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

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.dotWindow) {
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            self.dotWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screenWidth - 20, 10, 8, 8)];
            self.dotWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
            self.dotWindow.backgroundColor = [UIColor clearColor];
            self.dotWindow.userInteractionEnabled = NO;

            self.dotView = [[UIView alloc] initWithFrame:self.dotWindow.bounds];
            self.dotView.backgroundColor = [UIColor systemRedColor];
            self.dotView.layer.cornerRadius = 4.0;
            self.dotView.clipsToBounds = YES;
            [self.dotWindow addSubview:self.dotView];
        }
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

- (void)setupCaptureSession {
    NSDictionary *prefs = getPreferences();
    BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!enabled) return;

    self.session = [[AVCaptureSession alloc] init];
    [self.session beginConfiguration];

    self.session.sessionPreset = AVCaptureSessionPresetHigh;

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

    if (!self.session) {
        [self setupCaptureSession];
    }

    // Haptic Feedback
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
    if (!self.session.isRunning) {
        [self.session startRunning];
    }
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    [self.photoOutput capturePhotoWithSettings:settings delegate:self];
}

- (void)toggleVideoRecording {
    NSDictionary *prefs = getPreferences();
    BOOL showDot = prefs[@"ShowIndicatorDot"] ? [prefs[@"ShowIndicatorDot"] boolValue] : YES;

    if (self.isRecording) {
        [self.movieOutput stopRecording];
        if (self.session.isRunning) [self.session stopRunning];
        self.isRecording = NO;
        [[SneakyDotIndicator sharedInstance] hide];
    } else {
        if (!self.session.isRunning) [self.session startRunning];
        
        NSString *fileName = [NSString stringWithFormat:@"SneakyCam_%f.mov", [[NSDate date] timeIntervalSince1970]];
        NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
        [self.movieOutput startRecordingToOutputFileURL:fileURL recordingDelegate:self];
        self.isRecording = YES;

        if (showDot) {
            [[SneakyDotIndicator sharedInstance] show];
        }
    }
}

// Save Completed Video
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
    if (error) return;

    NSDictionary *prefs = getPreferences();
    NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;

    if (saveLocation == 0) {
        // Save to Camera Roll
        if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(outputFileURL.path)) {
            UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, nil, nil, nil);
        }
    } else {
        // Save to Documents (/var/mobile/Documents/SneakyCam/)
        NSString *dir = @"/var/mobile/Documents/SneakyCam";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dest = [dir stringByAppendingPathComponent:outputFileURL.lastPathComponent];
        [[NSFileManager defaultManager] moveItemAtPath:outputFileURL.path toPath:dest error:nil];
    }
}

// Save Completed Photo
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (error) return;

    NSData *data = [photo fileDataRepresentation];
    UIImage *image = [UIImage imageWithData:data];
    if (!image) return;

    NSDictionary *prefs = getPreferences();
    NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;

    if (saveLocation == 0) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
    } else {
        NSString *dir = @"/var/mobile/Documents/SneakyCam";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"SneakyCam_%f.jpg", [[NSDate date] timeIntervalSince1970]]];
        [data writeToFile:dest atomically:YES];
    }
}

@end

// Hook Volume Buttons in SpringBoard
%hook SBVolumeControl

- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down {
    if (down) {
        [[SneakyRecorder sharedInstance] triggerCapture];
    }
    %orig;
}

%end