#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "Fonts.h"
#import "LoaderConfig.h"
#import "Logger.h"
#import "Settings.h"
#import "Themes.h"
#import "Utils.h"

static NSURL         *source;
static NSString      *KettuTweakPatchesBundlePath;
static NSURL         *pyoncordDirectory;
static LoaderConfig  *loaderConfig;
static NSTimeInterval shakeStartTime = 0;
static BOOL           isShaking      = NO;
id                    gBridge        = nil;

%hook RCTCxxBridge

- (void)executeApplicationScript:(NSData *)script url:(NSURL *)url async:(BOOL)async
{
    if (![url.absoluteString containsString:@"main.jsbundle"])
    {
        return %orig;
    }

    gBridge = self;
    KettuTweakLog(@"Stored bridge reference: %@", gBridge);

    NSBundle *KettuTweakPatchesBundle = [NSBundle bundleWithPath:KettuTweakPatchesBundlePath];
    if (!KettuTweakPatchesBundle)
    {
        KettuTweakLog(@"Failed to load KettuTweakPatches bundle from path: %@", KettuTweakPatchesBundlePath);
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return %orig;
    }

    NSURL *patchPath = [KettuTweakPatchesBundle URLForResource:@"payload-base" withExtension:@"js"];
    if (!patchPath)
    {
        KettuTweakLog(@"Failed to find payload-base.js in bundle");
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return %orig;
    }

    NSData *patchData = [NSData dataWithContentsOfURL:patchPath];
    KettuTweakLog(@"Injecting loader");
    %orig(patchData, source, YES);

    __block NSData *bundle =
        [NSData dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]];

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    NSURL *bundleUrl;
    if (loaderConfig.customLoadUrlEnabled && loaderConfig.customLoadUrl)
    {
        bundleUrl = loaderConfig.customLoadUrl;
        KettuTweakLog(@"Using custom load URL: %@", bundleUrl.absoluteString);
    }
    else
    {
        bundleUrl = [NSURL
            URLWithString:@"https://codeberg.org/cocobo1/Kettu/raw/branch/dist/kettu.min.js"];
        KettuTweakLog(@"Using default bundle URL: %@", bundleUrl.absoluteString);
    }

    NSMutableURLRequest *bundleRequest =
        [NSMutableURLRequest requestWithURL:bundleUrl
                                cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                            timeoutInterval:3.0];

    NSString *bundleEtag = [NSString
        stringWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"etag.txt"]
                       encoding:NSUTF8StringEncoding
                          error:nil];
    if (bundleEtag && bundle)
    {
        [bundleRequest setValue:bundleEtag forHTTPHeaderField:@"If-None-Match"];
    }

    NSURLSession *session = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    __block BOOL downloadSuccessful = NO;

    [[session
        dataTaskWithRequest:bundleRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]])
            {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                if (httpResponse.statusCode == 200 && data && data.length > 0)
                {
                    bundle = data;
                    downloadSuccessful = YES;
                    [bundle
                        writeToURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]
                        atomically:YES];

                    NSString *etag = [httpResponse.allHeaderFields objectForKey:@"Etag"];
                    if (etag)
                    {
                        [etag
                            writeToURL:[pyoncordDirectory URLByAppendingPathComponent:@"etag.txt"]
                            atomically:YES
                                encoding:NSUTF8StringEncoding
                                error:nil];
                    }

                    KettuTweakLog(@"Bundle download successful, cleaning up backup");
                    cleanupBundleBackup();
                }
                else if (httpResponse.statusCode == 304)
                {
                    KettuTweakLog(@"Bundle not modified (304), cleaning up backup");
                    downloadSuccessful = YES;
                    cleanupBundleBackup();
                }
                else
                {
                    KettuTweakLog(@"Bundle download failed with status: %ld", (long)httpResponse.statusCode);
                }
            }
            else if (error)
            {
                KettuTweakLog(@"Bundle download error: %@", error.localizedDescription);
            }

            if (!downloadSuccessful && !bundle)
            {
                KettuTweakLog(@"No bundle available, attempting to restore from backup");
                if (restoreBundleFromBackup())
                {
                    bundle = [NSData dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]];
                    if (bundle)
                    {
                        KettuTweakLog(@"Successfully restored bundle from backup");
                    }
                }
                else
                {
                    KettuTweakLog(@"Failed to restore bundle from backup");
                }
            }

            dispatch_group_leave(group);
        }] resume];

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSData *themeData =
        [NSData dataWithContentsOfURL:[pyoncordDirectory
                                          URLByAppendingPathComponent:@"current-theme.json"]];
    if (themeData)
    {
        NSError      *jsonError;
        NSDictionary *themeDict = [NSJSONSerialization JSONObjectWithData:themeData
                                                                  options:0
                                                                    error:&jsonError];
        if (!jsonError)
        {
            KettuTweakLog(@"Loading theme data...");
            if (themeDict[@"data"])
            {
                NSDictionary *data = themeDict[@"data"];
                if (data[@"semanticColors"] && data[@"rawColors"])
                {
                    KettuTweakLog(@"Initializing theme colors from theme data");
                    initializeThemeColors(data[@"semanticColors"], data[@"rawColors"]);
                }
            }

            NSString *jsCode =
                [NSString stringWithFormat:@"globalThis.__PYON_LOADER__.storedTheme=%@",
                                           [[NSString alloc] initWithData:themeData
                                                                 encoding:NSUTF8StringEncoding]];
            %orig([jsCode dataUsingEncoding:NSUTF8StringEncoding], source, async);
        }
        else
        {
            KettuTweakLog(@"Error parsing theme JSON: %@", jsonError);
        }
    }
    else
    {
        KettuTweakLog(@"No theme data found at path: %@",
                 [pyoncordDirectory URLByAppendingPathComponent:@"current-theme.json"]);
    }

    NSData *fontData = [NSData
        dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"fonts.json"]];
    if (fontData)
    {
        NSError      *jsonError;
        NSDictionary *fontDict = [NSJSONSerialization JSONObjectWithData:fontData
                                                                 options:0
                                                                   error:&jsonError];
        if (!jsonError && fontDict[@"main"])
        {
            KettuTweakLog(@"Found font configuration, applying...");
            patchFonts(fontDict[@"main"], fontDict[@"name"]);
        }
    }

    if (bundle)
    {
        KettuTweakLog(@"Executing JS bundle");
        %orig(bundle, source, async);
    }
    else
    {
        KettuTweakLog(@"ERROR: No bundle available to execute!");
        showErrorAlert(@"Bundle Error",
                    @"Failed to load bundle. Please check your internet connection and restart the app.",
                    nil);
    }


    NSURL *preloadsDirectory = [pyoncordDirectory URLByAppendingPathComponent:@"preloads"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:preloadsDirectory.path])
    {
        NSError *error = nil;
        NSArray *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtURL:preloadsDirectory
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                               error:&error];
        if (!error)
        {
            for (NSURL *fileURL in contents)
            {
                if ([[fileURL pathExtension] isEqualToString:@"js"])
                {
                    KettuTweakLog(@"Executing preload JS file %@", fileURL.absoluteString);
                    NSData *data = [NSData dataWithContentsOfURL:fileURL];
                    if (data)
                    {
                        %orig(data, source, async);
                    }
                }
            }
        }
        else
        {
            KettuTweakLog(@"Error reading contents of preloads directory");
        }
    }

    %orig(script, url, async);
}

%end

%hook UIWindow

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake)
    {
        isShaking      = YES;
        shakeStartTime = [[NSDate date] timeIntervalSince1970];
    }
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake && isShaking)
    {
        NSTimeInterval currentTime   = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval shakeDuration = currentTime - shakeStartTime;

        if (shakeDuration >= 0.5 && shakeDuration <= 2.0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{ showSettingsSheet(); });
        }
        isShaking = NO;
    }
    %orig;
}

%end

%ctor
{
    @autoreleasepool
    {
        source = [NSURL URLWithString:@"kettu"];

        NSString *install_prefix = @"/var/jb";
        isJailbroken             = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];

        NSString *bundlePath =
            [NSString stringWithFormat:@"%@/Library/Application Support/KettuTweakResources.bundle",
                                       install_prefix];
        KettuTweakLog(@"Is jailbroken: %d", isJailbroken);
        KettuTweakLog(@"Bundle path for jailbroken: %@", bundlePath);

        NSString *jailedPath = [[NSBundle mainBundle].bundleURL.path
            stringByAppendingPathComponent:@"KettuTweakResources.bundle"];
        KettuTweakLog(@"Bundle path for jailed: %@", jailedPath);

        KettuTweakPatchesBundlePath = isJailbroken ? bundlePath : jailedPath;
        KettuTweakLog(@"Selected bundle path: %@", KettuTweakPatchesBundlePath);

        BOOL bundleExists =
            [[NSFileManager defaultManager] fileExistsAtPath:KettuTweakPatchesBundlePath];
        KettuTweakLog(@"Bundle exists at path: %d", bundleExists);

        NSError *error = nil;
        NSArray *bundleContents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:KettuTweakPatchesBundlePath
                                                                error:&error];
        if (error)
        {
            KettuTweakLog(@"Error listing bundle contents: %@", error);
        }
        else
        {
            KettuTweakLog(@"Bundle contents: %@", bundleContents);
        }

        pyoncordDirectory = getPyoncordDirectory();
        loaderConfig      = [[LoaderConfig alloc] init];
        [loaderConfig loadConfig];

        %init;
    }
}
