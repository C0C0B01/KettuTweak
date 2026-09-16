#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "JSI.h"
#import "LoaderConfig.h"
#import "Logger.h"
#import "RCTHost.h"
#import "Settings.h"
#import "Themes.h"
#import "Utils.h"

static NSString      *source = @"kettu";
static NSString      *bunnyPatchesBundlePath;
static NSURL         *pyoncordDirectory;
static LoaderConfig  *loaderConfig;
static NSTimeInterval shakeStartTime = 0;
static BOOL           isShaking      = NO;

%hook RCTHost

- (void)instance:(id)instance didInitializeRuntime:(facebook::jsi::Runtime &)runtime
{
    %orig;

    NSBundle *bunnyPatchesBundle = [NSBundle bundleWithPath:bunnyPatchesBundlePath];
    if (!bunnyPatchesBundle)
    {
        BunnyLog(@"Failed to load BunnyPatches bundle from path: %@", bunnyPatchesBundlePath);
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return;
    }

    NSURL *patchPath = [bunnyPatchesBundle URLForResource:@"payload-base" withExtension:@"js"];
    if (!patchPath)
    {
        BunnyLog(@"Failed to find payload-base.js in bundle");
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return;
    }

    NSData *patchData = [NSData dataWithContentsOfURL:patchPath];
    BunnyLog(@"Injecting loader");
    [JSI evaluate:patchData tag:source runtime:runtime];

    __block NSData *bundle =
        [NSData dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]];

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    NSURL *bundleUrl;
    if (loaderConfig.customLoadUrlEnabled && loaderConfig.customLoadUrl)
    {
        bundleUrl = loaderConfig.customLoadUrl;
        BunnyLog(@"Using custom load URL: %@", bundleUrl.absoluteString);
    }
    else
    {
        bundleUrl = [NSURL
            URLWithString:@"https://codeberg.org/cocobo1/Kettu/raw/branch/dist/kettu.min.js"];
        BunnyLog(@"Using default bundle URL: %@", bundleUrl.absoluteString);
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

    NSURLSession *session            = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    __block BOOL  downloadSuccessful = NO;

    [[session
        dataTaskWithRequest:bundleRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              if ([response isKindOfClass:[NSHTTPURLResponse class]])
              {
                  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                  if (httpResponse.statusCode == 200 && data && data.length > 0)
                  {
                      bundle             = data;
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

                      BunnyLog(@"Bundle download successful, cleaning up backup");
                      cleanupBundleBackup();
                  }
                  else if (httpResponse.statusCode == 304)
                  {
                      BunnyLog(@"Bundle not modified (304), cleaning up backup");
                      downloadSuccessful = YES;
                      cleanupBundleBackup();
                  }
                  else
                  {
                      BunnyLog(@"Bundle download failed with status: %ld",
                               (long) httpResponse.statusCode);
                  }
              }
              else if (error)
              {
                  BunnyLog(@"Bundle download error: %@", error.localizedDescription);
              }

              if (!downloadSuccessful && !bundle)
              {
                  BunnyLog(@"No bundle available, attempting to restore from backup");
                  if (restoreBundleFromBackup())
                  {
                      bundle = [NSData
                          dataWithContentsOfURL:[pyoncordDirectory
                                                    URLByAppendingPathComponent:@"bundle.js"]];
                      if (bundle)
                      {
                          BunnyLog(@"Successfully restored bundle from backup");
                      }
                  }
                  else
                  {
                      BunnyLog(@"Failed to restore bundle from backup");
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
            BunnyLog(@"Loading theme data...");
            if (themeDict[@"data"])
            {
                NSDictionary *data = themeDict[@"data"];
                if (data[@"semanticColors"] && data[@"rawColors"])
                {
                    BunnyLog(@"Initializing theme colors from theme data");
                    initializeThemeColors(data[@"semanticColors"], data[@"rawColors"]);
                }
            }

            NSString *jsCode =
                [NSString stringWithFormat:@"globalThis.__PYON_LOADER__.storedTheme=%@",
                                           [[NSString alloc] initWithData:themeData
                                                                 encoding:NSUTF8StringEncoding]];
            [JSI evaluate:[jsCode dataUsingEncoding:NSUTF8StringEncoding]
                      tag:source
                  runtime:runtime];
        }
        else
        {
            BunnyLog(@"Error parsing theme JSON: %@", jsonError);
        }
    }
    else
    {
        BunnyLog(@"No theme data found at path: %@",
                 [pyoncordDirectory URLByAppendingPathComponent:@"current-theme.json"]);
    }

    if (bundle)
    {
        BunnyLog(@"Executing JS bundle");
        [JSI evaluate:bundle tag:source runtime:runtime];
    }
    else
    {
        BunnyLog(@"ERROR: No bundle available to execute!");
        showErrorAlert(
            @"Bundle Error",
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
                    BunnyLog(@"Executing preload JS file %@", fileURL.absoluteString);
                    NSData *data = [NSData dataWithContentsOfURL:fileURL];
                    if (data)
                    {
                        [JSI evaluate:data tag:source runtime:runtime];
                    }
                }
            }
        }
        else
        {
            BunnyLog(@"Error reading contents of preloads directory");
        }
    }
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
        NSString *install_prefix = @"/var/jb";
        isJailbroken             = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];
        BOOL jbPathExists        = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];

        NSString *bundlePath =
            [NSString stringWithFormat:@"%@/Library/Application Support/BunnyResources.bundle",
                                       install_prefix];
        BunnyLog(@"Is jailbroken: %d", isJailbroken);
        BunnyLog(@"Bundle path for jailbroken: %@", bundlePath);

        NSString *jailedPath = [[NSBundle mainBundle].bundleURL.path
            stringByAppendingPathComponent:@"BunnyResources.bundle"];
        BunnyLog(@"Bundle path for jailed: %@", jailedPath);

        bunnyPatchesBundlePath = isJailbroken ? bundlePath : jailedPath;
        BunnyLog(@"Selected bundle path: %@", bunnyPatchesBundlePath);

        BOOL bundleExists =
            [[NSFileManager defaultManager] fileExistsAtPath:bunnyPatchesBundlePath];
        BunnyLog(@"Bundle exists at path: %d", bundleExists);

        if (jbPathExists)
        {
            BunnyLog(@"Jailbreak path exists, attempting to load bundle from: %@", bundlePath);

            BOOL      bundleExists = [[NSFileManager defaultManager] fileExistsAtPath:bundlePath];
            NSBundle *testBundle   = [NSBundle bundleWithPath:bundlePath];

            if (bundleExists && testBundle)
            {
                bunnyPatchesBundlePath = bundlePath;
                BunnyLog(@"Successfully loaded bundle from jailbroken path");
            }
            else
            {
                BunnyLog(@"Bundle not found or invalid at jailbroken path, falling back to jailed");
                bunnyPatchesBundlePath = jailedPath;
            }
        }
        else
        {
            BunnyLog(@"Not jailbroken, using jailed bundle path");
            bunnyPatchesBundlePath = jailedPath;
        }

        BunnyLog(@"Selected bundle path: %@", bunnyPatchesBundlePath);

        NSBundle *bunnyPatchesBundle = [NSBundle bundleWithPath:bunnyPatchesBundlePath];
        if (!bunnyPatchesBundle)
        {
            BunnyLog(@"Failed to load bunnyPatches bundle from any path");
            BunnyLog(@"  Jailbroken path: %@", bundlePath);
            BunnyLog(@"  Jailed path: %@", jailedPath);
            BunnyLog(@"  /var/jb exists: %d", jbPathExists);

            bunnyPatchesBundlePath = nil;
        }
        else
        {
            BunnyLog(@"Bundle loaded successfully");
            NSError *error = nil;
            NSArray *bundleContents =
                [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bunnyPatchesBundlePath
                                                                    error:&error];
            if (error)
            {
                BunnyLog(@"Error listing bundle contents: %@", error);
            }
            else
            {
                BunnyLog(@"Bundle contents: %@", bundleContents);
            }
        }

        pyoncordDirectory = getPyoncordDirectory();
        loaderConfig      = [[LoaderConfig alloc] init];
        [loaderConfig loadConfig];

        %init;
    }
}
