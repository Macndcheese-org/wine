/*
 * Launcher of the MNC Wine application bundle.
 *
 * Opening the application without a document opens a Terminal window whose shell has Wine's
 * bin directory first in PATH and shows the welcome text of the WineHQ application (start/bin/winehelp,
 * taken from its packaging, with appdb).  Opening a Windows
 * program with it (double click, "Open With", drop on the Dock icon) runs the program with
 * "wine start /unix" and does not open Terminal.
 *
 * Nothing here sets DYLD_* variables: the libraries Wine needs are inside the bundle and are
 * found through the run paths of the binaries (see packaging/bundle-dylibs.py).
 */

#import <Cocoa/Cocoa.h>

@interface MNCWineDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) BOOL handledDocuments;
@end

static NSString *WineBinDirectory(void)
{
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"wine/bin"];
}

static NSString *StartDirectory(void)
{
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"start/bin"];
}

static NSString *ShellQuote(NSString *string)
{
    return [NSString stringWithFormat:@"'%@'", [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *AppleScriptQuote(NSString *string)
{
    string = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [NSString stringWithFormat:@"\"%@\"", [string stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
}

static void OpenTerminal(void)
{
    /* setenv() works in csh and tcsh; the test defines it for the shells that only know export. */
    NSString *command = [NSString stringWithFormat:
        @"test \"$?BASH_VERSION\" = \"0\" || eval 'setenv() { export \"$1=$2\"; }'; "
        @"setenv PATH %@:%@:\"$PATH\"; winehelp --clear",
        ShellQuote(WineBinDirectory()), ShellQuote(StartDirectory())];
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n activate\n do script %@\nend tell", AppleScriptQuote(command)];
    NSDictionary *error = nil;

    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
    if (error) NSLog(@"Could not open Terminal: %@", error[NSAppleScriptErrorMessage]);
}

static void RunPrograms(NSArray<NSString *> *files)
{
    NSString *bin = WineBinDirectory();

    for (NSString *file in files)
    {
        NSTask *task = [[NSTask alloc] init];
        NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];

        environment[@"PATH"] = [NSString stringWithFormat:@"%@:%@", bin, environment[@"PATH"] ?: @"/usr/bin:/bin"];
        task.executableURL = [NSURL fileURLWithPath:[bin stringByAppendingPathComponent:@"wine"]];
        task.arguments = @[@"start", @"/unix", file];
        task.currentDirectoryURL = [NSURL fileURLWithPath:[file stringByDeletingLastPathComponent]];
        task.environment = environment;
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) NSLog(@"Could not run %@: %@", file, error);
    }
}

@implementation MNCWineDelegate

- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)files
{
    self.handledDocuments = YES;
    RunPrograms(files);
    [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
    [application terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    /* Documents arrive before this notification, so by now we know which kind of launch it is. */
    if (!self.handledDocuments)
    {
        OpenTerminal();
        [NSApp terminate:nil];
    }
}

@end

int main(void)
{
    @autoreleasepool
    {
        NSApplication *application = [NSApplication sharedApplication];
        MNCWineDelegate *delegate = [[MNCWineDelegate alloc] init];

        application.delegate = delegate;
        [application run];
    }
    return 0;
}
