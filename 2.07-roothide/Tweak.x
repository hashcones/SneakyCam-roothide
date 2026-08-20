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

// Indicator Dot Window + Frame Pipeline Activator
@interface SneakyDotIndicator : NSObject
@property (nonatomic, strong) UIWindow *dotWindow;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
+ (instancetype)sharedInstance;
- (void)attachSession:(AVCaptureSession *)session;
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

- (void)attachSession:(AVCaptureSession *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.previewLayer) {
            [self.previewLayer removeFromSuperlayer];
        }
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
        self.previewLayer.frame = CGRectMake(0, 0, 1, 1);
        self.previewLayer.opacity = 0.01; // Invisible
        [self.dotWindow.layer addSublayer:self.previewLayer];
        SneakyLog(@"Attached preview layer to window hierarchy.");
    });
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dotView.hidden = NO;
        self.dotWindow.hidden = NO;
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dotView.hidden = YES;
        // Keep window unhidden with 1x1 layer so frames continue while finalizing
    });
}
@end

// Recorder Controller
@interface SneakyRecorder : NSObject <AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) NSInteger currentMode;
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
        self.sessionQueue = dispatch_queue_create("com.sparkdev.sneakycam.sessionQueue", DISPATCH_QUEUE_SERIAL);
        self.currentMode = -1;
    }
    return self;
}

- (void)configureSessionForMode:(NSInteger)mode {
    if (!self.session) {
        self.session = [[AVCaptureSession alloc] init];
        [[SneakyDotIndicator sharedInstance] attachSession:self.session];
    }

    [self.session beginConfiguration];

    for (AVCaptureInput *input in [self.session.inputs copy]) {
        [self.session removeInput:input];
    }
    for (AVCaptureOutput *output in [self.session.outputs copy]) {
        [self.session removeOutput:output];
    }

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
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
        if (input && [self.session canAddInput:input]) {
            [self.session addInput:input];
        }
    }

    if (mode == 0) {
        if ([self.session canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
            self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        }
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        if ([self.session canAddOutput:self.photoOutput]) {
            [self.session addOutput:self.photoOutput];
        }
        SneakyLog(@"Configured for PHOTO mode.");
    } else {
        if ([self.session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            self.session.sessionPreset = AVCaptureSessionPresetHigh;
        }
        self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
        if ([self.session canAddOutput:self.movieOutput]) {
            [self.session addOutput:self.movieOutput];
        }
        SneakyLog(@"Configured for VIDEO mode.");
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

        [NSThread sleepForTimeInterval:0.4];

        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
        [self.photoOutput capturePhotoWithSettings:settings delegate:self];
        SneakyLog(@"capturePhoto dispatched.");
    });
}

- (void)toggleVideoRecording {
    if (self.isRecording) {
        SneakyLog(@"Stopping recording. Current movieOutput.isRecording = %d", self.movieOutput.isRecording);
        if (self.movieOutput.isRecording) {
            [self.movieOutput stopRecording];
        } else {
            dispatch_async(self.sessionQueue, ^{
                if (self.session.isRunning) [self.session stopRunning];
            });
        }
        self.isRecording = NO;
        [[SneakyDotIndicator sharedInstance] hide];
    } else {
        SneakyLog(@"Starting video recording...");
        dispatch_async(self.sessionQueue, ^{
            [self configureSessionForMode:1];

            if (!self.session.isRunning) {
                [self.session startRunning];
                SneakyLog(@"Camera session startRunning called.");
            }

            // Wait 350ms for the previewLayer to begin streaming hardware frames
            [NSThread sleepForTimeInterval:0.35];

            NSString *dir = @"/var/mobile/Documents/SneakyCam";
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *fileName = [NSString stringWithFormat:@"SneakyCam_%ld.mov", (long)[[NSDate date] timeIntervalSince1970]];
            NSURL *fileURL = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:fileName]];

            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.movieOutput startRecordingToOutputFileURL:fileURL recordingDelegate:self];
                self.isRecording = YES;
                SneakyLog(@"startRecording directed to: %@", fileURL.path);

                NSDictionary *prefs = getPreferences();
                if (prefs[@"ShowIndicatorDot"] ? [prefs[@"ShowIndicatorDot"] boolValue] : YES) {
                    [[SneakyDotIndicator sharedInstance] show];
                }
            });
        });
    }
}

// Delegate: Video Finished
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
    SneakyLog(@"captureOutput delegate called for URL: %@", outputFileURL.path);
    if (error) {
        SneakyLog(@"Video error: %@ (Code: %ld)", error.localizedDescription, (long)error.code);
    }

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path];
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputFileURL.path error:nil] fileSize];
    SneakyLog(@"Video saved to disk: exists=%d, size=%llu bytes", exists, size);

    if (exists && size > 0) {
        NSDictionary *prefs = getPreferences();
        NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;
        if (saveLocation == 0 && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(outputFileURL.path)) {
            UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, nil, nil, nil);
            SneakyLog(@"Video exported to Photos Camera Roll.");
        }
    }

    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
            SneakyLog(@"Camera session stopped.");
        }
    });
}

// Delegate: Photo Finished
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (error) {
        SneakyLog(@"Photo error: %@ (Code: %ld)", error.localizedDescription, (long)error.code);
        return;
    }

    NSData *data = [photo fileDataRepresentation];
    if (!data) {
        SneakyLog(@"Photo data is nil.");
        return;
    }

    UIImage *image = [UIImage imageWithData:data];
    NSString *dir = @"/var/mobile/Documents/SneakyCam";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"SneakyCam_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
    [data writeToFile:dest atomically:YES];
    SneakyLog(@"Photo saved to disk: %@", dest);

    NSDictionary *prefs = getPreferences();
    NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;
    if (saveLocation == 0 && image) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        SneakyLog(@"Photo exported to Photos Camera Roll.");
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