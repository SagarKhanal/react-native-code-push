#import "RCTBridgeModule.h"
#import "RCTEventDispatcher.h"
#import "RCTConvert.h"
#import "RCTRootView.h"
#import "RCTUtils.h"
#import "CodePush.h"

@implementation CodePush {
    BOOL _resumablePendingUpdateAvailable;
}

RCT_EXPORT_MODULE()

static BOOL didUpdate = NO;
static NSTimer *_timer;
static BOOL usingTestFolder = NO;

static NSString * const FailedUpdatesKey = @"CODE_PUSH_FAILED_UPDATES";
static NSString * const PendingUpdateKey = @"CODE_PUSH_PENDING_UPDATE";

// These keys are already "namespaced" by the PendingUpdateKey, so
// their values don't need to be obfuscated to prevent collision with app data
static NSString * const PendingUpdateHashKey = @"hash";
static NSString * const PendingUpdateRollbackTimeoutKey = @"rollbackTimeout";

@synthesize bridge = _bridge;

+ (NSURL *)bundleURL
{
    return [self bundleURLForResourceName:@"main"
                            withExtension:@"jsbundle"];
}

+ (NSURL *)bundleURLForResourceName:(NSString *)resourceName
{
    return [self bundleURLForResourceName:resourceName
                            withExtension:@"jsbundle"];
}

+ (NSURL *)bundleURLForResourceName:(NSString *)resourceName
                      withExtension:(NSString *)resourceExtension
{
    NSError *error;
    NSString *packageFile = [CodePushPackage getCurrentPackageBundlePath:&error];
    NSURL *binaryJsBundleUrl = [[NSBundle mainBundle] URLForResource:resourceName withExtension:resourceExtension];
    
    if (error || !packageFile)
    {
        return binaryJsBundleUrl;
    }
    
    NSDictionary *binaryFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[binaryJsBundleUrl path] error:nil];
    NSDictionary *appFileAttribs = [[NSFileManager defaultManager] attributesOfItemAtPath:packageFile error:nil];
    NSDate *binaryDate = [binaryFileAttributes objectForKey:NSFileModificationDate];
    NSDate *packageDate = [appFileAttribs objectForKey:NSFileModificationDate];
    
    if ([binaryDate compare:packageDate] == NSOrderedAscending) {
        // Return package file because it is newer than the app store binary's JS bundle
        return [[NSURL alloc] initFileURLWithPath:packageFile];
    } else {
        return binaryJsBundleUrl;
    }
}

// Public Obj-C API
+ (NSString *)getDocumentsDirectory
{
    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return documentsDirectory;
}

// Internal API methods
- (void)cancelRollbackTimer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [_timer invalidate];
    });
}

- (void)checkForPendingUpdate:(BOOL)needsRestart
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
        NSDictionary *pendingUpdate = [preferences objectForKey:PendingUpdateKey];
        
        if (pendingUpdate) {
            NSError *error;
            NSString *pendingHash = pendingUpdate[PendingUpdateHashKey];
            NSString *currentHash = [CodePushPackage getCurrentPackageHash:&error];
            
            // If the current hash is equivalent to the pending hash, then the app
            // restart "picked up" the new update, but we need to kick off the
            // rollback timer and ensure that the necessary state is setup.
            if ([pendingHash isEqualToString:currentHash]) {
                int rollbackTimeout = [pendingUpdate[PendingUpdateRollbackTimeoutKey] intValue];
                [self initializeUpdateWithRollbackTimeout:rollbackTimeout needsRestart:needsRestart];
                
                // Clear the pending update and sync
                [preferences removeObjectForKey:PendingUpdateKey];
                [preferences synchronize];
            }
        }
    });
}

- (void)checkForPendingUpdateDuringResume
{
    // In order to ensure that CodePush doesn't impact the app's
    // resume experience, we're using a simple boolean check to
    // check whether we need to restart, before reading the defaults store
    if (_resumablePendingUpdateAvailable) {
        [self checkForPendingUpdate:YES];
    }
}

- (NSDictionary *)constantsToExport
{
    // Export the values of the CodePushInstallMode enum
    // so that the script-side can easily stay in sync
    return @{ @"codePushInstallModeOnNextRestart":@(CodePushInstallModeOnNextRestart),
              @"codePushInstallModeImmediate": @(CodePushInstallModeImmediate),
              @"codePushInstallModeOnNextResume": @(CodePushInstallModeOnNextResume)
            };
};

- (void)dealloc
{
    // Ensure the global resume handler is cleared, so that
    // this object isn't kept alive unnecessarily
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)init
{
    self = [super init];
    
    if (self) {
        // Do an async check to see whether
        // we need to start the rollback timer
        // due to a pending update being installed at start
        [self checkForPendingUpdate:NO];
        
        // Register for app resume notifications so that we
        // can check for pending updates which support "restart on resume"
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(checkForPendingUpdateDuringResume)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:[UIApplication sharedApplication]];
    }
    
    return self;
}

- (void)initializeUpdateWithRollbackTimeout:(int)rollbackTimeout
                               needsRestart:(BOOL)needsRestart
{
    didUpdate = YES;
    
    if (needsRestart) {
        [self loadBundle];
    }
    
    if (0 != rollbackTimeout) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startRollbackTimer:rollbackTimeout];
        });
    }
}

- (BOOL)isFailedHash:(NSString*)packageHash
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSMutableArray *failedUpdates = [preferences objectForKey:FailedUpdatesKey];
    return (failedUpdates != nil && [failedUpdates containsObject:packageHash]);
}

- (void)loadBundle
{
    // If the current bundle URL is using http(s), then assume the dev
    // is debugging and therefore, shouldn't be redirected to a local
    // file (since Chrome wouldn't support it). Otherwise, update
    // the current bundle URL to point at the latest update
    if (![_bridge.bundleURL.scheme hasPrefix:@"http"]) {
        _bridge.bundleURL = [CodePush bundleURL];
    }
    
    [_bridge reload];
}

- (void)rollbackPackage
{
    NSError *error;
    NSString *packageHash = [CodePushPackage getCurrentPackageHash:&error];
    
    // Write the current package's hash to the "failed list"
    [self saveFailedUpdate:packageHash];
    
    // Do the actual rollback and then
    // refresh the app with the previous package
    [CodePushPackage rollbackPackage];
    [self loadBundle];
}

- (void)saveFailedUpdate:(NSString *)packageHash
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSMutableArray *failedUpdates = [preferences objectForKey:FailedUpdatesKey];
    if (failedUpdates == nil) {
        failedUpdates = [[NSMutableArray alloc] init];
    } else {
        // The NSUserDefaults sytem always returns immutable
        // objects, regardless if you stored something mutable.
        failedUpdates = [failedUpdates mutableCopy];
    }
    
    [failedUpdates addObject:packageHash];
    [preferences setObject:failedUpdates forKey:FailedUpdatesKey];
    [preferences synchronize];
}

- (void)savePendingUpdate:(NSString *)packageHash
          rollbackTimeout:(int)rollbackTimeout
{
    // Since we're not restarting, we need to store the fact that the update
    // was installed, but hasn't yet become "active".
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSDictionary *pendingUpdate = [[NSDictionary alloc] initWithObjectsAndKeys:
                                   packageHash,PendingUpdateHashKey,
                                   [NSNumber numberWithInt:rollbackTimeout],PendingUpdateRollbackTimeoutKey, nil];
    
    [preferences setObject:pendingUpdate forKey:PendingUpdateKey];
    [preferences synchronize];
}

- (void)startRollbackTimer:(int)rollbackTimeout
{
    double timeoutInSeconds = rollbackTimeout / 1000;
    _timer = [NSTimer scheduledTimerWithTimeInterval:timeoutInSeconds
                                              target:self
                                            selector:@selector(rollbackPackage)
                                            userInfo:nil
                                             repeats:NO];
}

// JavaScript-exported module methods
RCT_EXPORT_METHOD(downloadUpdate:(NSDictionary*)updatePackage
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [CodePushPackage downloadPackage:updatePackage
                    progressCallback:^(long expectedContentLength, long receivedContentLength) {
                        [self.bridge.eventDispatcher
                         sendAppEventWithName:@"CodePushDownloadProgress"
                         body:@{
                                @"totalBytes":[NSNumber numberWithLong:expectedContentLength],
                                @"receivedBytes":[NSNumber numberWithLong:receivedContentLength]
                                }];
                    }
                        doneCallback:^{
                            NSError *err;
                            NSDictionary *newPackage = [CodePushPackage
                                                        getPackage:updatePackage[@"packageHash"]
                                                        error:&err];
                            
                            if (err) {
                                return reject(err);
                            }
                            
                            resolve(newPackage);
                        }
                        failCallback:^(NSError *err) {
                            reject(err);
                        }];
}

RCT_EXPORT_METHOD(getConfiguration:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    resolve([[CodePushConfig current] configuration]);
}

RCT_EXPORT_METHOD(getCurrentPackage:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error;
        NSDictionary *package = [CodePushPackage getCurrentPackage:&error];
        if (error) {
            reject(error);
        } else {
            resolve(package);
        }
    });
}

RCT_EXPORT_METHOD(installUpdate:(NSDictionary*)updatePackage
                  rollbackTimeout:(int)rollbackTimeout
                  installMode:(CodePushInstallMode)installMode
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        [CodePushPackage installPackage:updatePackage
                                  error:&error];
        
        if (error) {
            reject(error);
        } else {
            if (installMode != CodePushInstallModeImmediate) {
                _resumablePendingUpdateAvailable = (installMode == CodePushInstallModeOnNextResume);
                [self savePendingUpdate:updatePackage[@"packageHash"]
                        rollbackTimeout:rollbackTimeout];
            }
            // Signal to JS that the update has been applied.
            resolve(nil);
        }
    });
}

RCT_EXPORT_METHOD(isFailedUpdate:(NSString *)packageHash
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    BOOL isFailedHash = [self isFailedHash:packageHash];
    resolve(@(isFailedHash));
}

RCT_EXPORT_METHOD(isFirstRun:(NSString *)packageHash
                     resolve:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
{
    NSError *error;
    BOOL isFirstRun = didUpdate
    && nil != packageHash
    && [packageHash length] > 0
    && [packageHash isEqualToString:[CodePushPackage getCurrentPackageHash:&error]];
    
    resolve(@(isFirstRun));
}

RCT_EXPORT_METHOD(notifyApplicationReady:(RCTPromiseResolveBlock)resolve
                                rejecter:(RCTPromiseRejectBlock)reject)
{
    [self cancelRollbackTimer];
    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(restartApp:(int)rollbackTimeout){
    [self initializeUpdateWithRollbackTimeout:rollbackTimeout needsRestart:YES];
}

RCT_EXPORT_METHOD(setDeploymentKey:(NSString *)deploymentKey
                           resolve:(RCTPromiseResolveBlock)resolve
                          rejecter:(RCTPromiseRejectBlock)reject)
{
    [[CodePushConfig current] setDeploymentKey:deploymentKey];
    resolve(nil);
}

RCT_EXPORT_METHOD(setUsingTestFolder:(BOOL)shouldUseTestFolder)
{
    usingTestFolder = shouldUseTestFolder;
}

@end