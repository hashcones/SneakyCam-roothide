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

// Indicator Dot
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
            self.dotWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screenWidth - 24, 12, 10, 10)];
            self.dotWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
            self.dotWindow.backgroundColor = [UIColor clearColor];
            self.dotWindow.userInteractionEnabled = NO;

            self.dotView = [[UIView alloc] initWithFrame:self.dotWindow.bounds];
            self.dotView.backgroundColor = [UIColor systemRedColor];
            self.dotView.layer.cornerRadius = 5.0;
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

// Recorder Singleton
@interface SneakyRecorder : NSObject <AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
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
        [self setupCaptureSession];
    }
    return self;
}

- (void)setupCaptureSession {
    dispatch_async(self.sessionQueue, ^{
        SneakyLog(@"Configuring AVCaptureSession...");
        self.session = [[AVCaptureSession alloc] init];
        [self.session beginConfiguration];

        self.session.sessionPreset = AVCaptureSessionPresetHigh;

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
            AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&err];
            if (videoInput && [self.session canAddInput:videoInput]) {
                [self.session addInput:videoInput];
                SneakyLog(@"Video device input connected: %@", videoDevice.localizedName);
            } else {
                SneakyLog(@"Failed adding video input: %@", err.localizedDescription);
            }
        }

        // Add Movie Output
        self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
        if ([self.session canAddOutput:self.movieOutput]) {
            [self.session addOutput:self.movieOutput];
            SneakyLog(@"Movie output attached.");
        }

        // Add Photo Output
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        if ([self.session canAddOutput:self.photoOutput]) {
            [self.session addOutput:self.photoOutput];
        }

        [self.session commitConfiguration];
        SneakyLog(@"AVCaptureSession configuration committed.");
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

    NSInteger captureMode = prefs[@"CaptureMode"] ? [prefs[@"CaptureMode"] integerValue] : 1;
    if (captureMode == 0) {
        [self capturePhoto];
    } else {
        [self toggleVideoRecording];
    }
}

- (void)capturePhoto {
    dispatch_async(self.sessionQueue, ^{
        if (!self.session.isRunning) {
            [self.session startRunning];
            [NSThread sleepForTimeInterval:0.25];
        }
        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
        [self.photoOutput capturePhotoWithSettings:settings delegate:self];
        SneakyLog(@"Photo capture request sent.");
    });
}

- (void)toggleVideoRecording {
    if (self.isRecording) {
        SneakyLog(@"Stopping video recording... (movieOutput.isRecording = %d)", self.movieOutput.isRecording);
        if (self.movieOutput.isRecording) {
            [self.movieOutput stopRecording];
        } else {
            SneakyLog(@"WARNING: movieOutput was not active. Stopping session.");
            dispatch_async(self.sessionQueue, ^{
                if (self.session.isRunning) [self.session stopRunning];
            });
        }
        self.isRecording = NO;
        [[SneakyDotIndicator sharedInstance] hide];
    } else {
        SneakyLog(@"Starting video recording...");
        dispatch_async(self.sessionQueue, ^{
            if (!self.session) {
                [self setupCaptureSession];
            }

            if (!self.session.isRunning) {
                [self.session startRunning];
                SneakyLog(@"Camera session startRunning called.");
            }

            // Wait for the video connection to become active
            AVCaptureConnection *conn = [self.movieOutput connectionWithMediaType:AVMediaTypeVideo];
            int waitCycles = 0;
            while ((!conn || !conn.isActive) && waitCycles < 10) {
                [NSThread sleepForTimeInterval:0.1];
                conn = [self.movieOutput connectionWithMediaType:AVMediaTypeVideo];
                waitCycles++;
            }
            SneakyLog(@"Connection status after %dms: active=%d, enabled=%d", waitCycles * 100, conn.isActive, conn.isEnabled);

            NSString *dir = @"/var/mobile/Documents/SneakyCam";
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *fileName = [NSString stringWithFormat:@"SneakyCam_%ld.mov", (long)[[NSDate date] timeIntervalSince1970]];
            NSURL *fileURL = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:fileName]];

            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.movieOutput startRecordingToOutputFileURL:fileURL recordingDelegate:self];
                self.isRecording = YES;
                SneakyLog(@"startRecording dispatched to: %@", fileURL.path);

                NSDictionary *prefs = getPreferences();
                if (prefs[@"ShowIndicatorDot"] ? [prefs[@"ShowIndicatorDot"] boolValue] : YES) {
                    [[SneakyDotIndicator sharedInstance] show];
                }
            });
        });
    }
}

// Delegate: Video recording finished
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
    SneakyLog(@"captureOutput delegate called for: %@", outputFileURL.path);
    if (error) {
        SneakyLog(@"Recording finished with error: %@ (Code: %ld)", error.localizedDescription, (long)error.code);
    }

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path];
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputFileURL.path error:nil] fileSize];
    SneakyLog(@"File on disk: exists=%d, size=%llu bytes", exists, size);

    if (exists && size > 0) {
        NSDictionary *prefs = getPreferences();
        NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;
        if (saveLocation == 0) {
            if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(outputFileURL.path)) {
                UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, self, @selector(video:didFinishSavingWithError:contextInfo:), nil);
            }
        }
    }

    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
            SneakyLog(@"Camera session stopped.");
        }
    });
}

- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        SneakyLog(@"Photos album export error: %@", error.localizedDescription);
    } else {
        SneakyLog(@"Video saved to Photos Camera Roll.");
    }
}

// Delegate: Photo finished
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (error) {
        SneakyLog(@"Photo error: %@", error.localizedDescription);
        return;
    }

    NSData *data = [photo fileDataRepresentation];
    UIImage *image = [UIImage imageWithData:data];
    if (!image) return;

    NSDictionary *prefs = getPreferences();
    NSInteger saveLocation = prefs[@"SaveLocation"] ? [prefs[@"SaveLocation"] integerValue] : 0;

    NSString *dir = @"/var/mobile/Documents/SneakyCam";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"SneakyCam_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
    [data writeToFile:dest atomically:YES];
    SneakyLog(@"Photo saved: %@", dest);

    if (saveLocation == 0) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        SneakyLog(@"Photo exported to Photos Camera Roll.");
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