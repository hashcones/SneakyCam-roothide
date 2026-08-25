#import "SneakyCamRootListController.h"
#import <spawn.h>

@implementation SneakyCamRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
}

- (void)clearLogFile {
    NSString *logPath = @"/var/mobile/Documents/SneakyCam.log";
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SneakyCam"
                                                                   message:@"Log file cleared successfully."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
