#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface SBVolumeControl : NSObject
- (void)handleVolumeButtonWithKeyType:(char)keyType down:(BOOL)isDown;
@end

@interface SneakyRecorder : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureMovieFileOutput *output;
@property (nonatomic, assign) BOOL isRecording;
+ (instancetype)sharedInstance;
- (void)toggleRecording;
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
    self.session = [[AVCaptureSession alloc] init];
    [self.session beginConfiguration];

    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];

    if (videoInput && [self.session canAddInput:videoInput]) {
        [self.session addInput:videoInput];
    }

    self.output = [[AVCaptureMovieFileOutput alloc] init];
    if ([self.session canAddOutput:self.output]) {
        [self.session addOutput:self.output];
    }

    [self.session commitConfiguration];
}

- (void)toggleRecording {
    if (self.isRecording) {
        [self stopRecording];
    } else {
        [self startRecording];
    }
}

- (void)startRecording {
    if (!self.session.isRunning) {
        [self.session startRunning];
    }
    
    NSString *fileName = [NSString stringWithFormat:@"capture_%f.mov", [[NSDate date] timeIntervalSince1970]];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
    
    [self.output startRecordingToOutputFileURL:fileURL recordingDelegate:self];
    self.isRecording = YES;
}

- (void)stopRecording {
    if (self.output.isRecording) {
        [self.output stopRecording];
    }
    if (self.session.isRunning) {
        [self.session stopRunning];
    }
    self.isRecording = NO;
}

- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
    // Media file saved to temporary directory
}

@end

%hook SBVolumeControl

- (void)handleVolumeButtonWithKeyType:(char)keyType down:(BOOL)isDown {
    if (isDown) {
        // Toggle background recording session
        [[SneakyRecorder sharedInstance] toggleRecording];
    }
    %orig;
}

%end