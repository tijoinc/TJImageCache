// TJImageCache
// By Tim Johnsen

#import "TJImageCache.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *_tj_imageCacheRootPath;

static NSNumber *_tj_imageCacheBaseSize;
static long long _tj_imageCacheDeltaSize;
static NSNumber *_tj_imageCacheApproximateCacheSize;

@interface TJImageCacheNoOpDelegate : NSObject <TJImageCacheDelegate>

@end

#if defined(__has_attribute) && __has_attribute(objc_direct_members)
__attribute__((objc_direct_members))
#endif
@implementation TJImageCacheNoOpDelegate

- (void)didGetImage:(IMAGE_CLASS *)image atURL:(NSString *)url
{
    // intentional no-op
}

@end

@interface NSHashTable (TJImageCacheAdditions)

- (BOOL)tj_isEmpty;

@end

#if defined(__has_attribute) && __has_attribute(objc_direct_members)
__attribute__((objc_direct_members))
#endif
@implementation NSHashTable (TJImageCacheAdditions)

- (BOOL)tj_isEmpty
{
    // NSHashTable can sometimes misreport "count"
    // This seems to be a surefire way to check if a hash table is truly empty.
    // https://stackoverflow.com/a/29882356/3943258
    return !self.anyObject;
}

@end

#if defined(__has_attribute) && __has_attribute(objc_direct_members)
__attribute__((objc_direct_members))
#endif
@implementation TJImageCache

#pragma mark - Configuration

+ (void)configureWithRootPath:(NSString *const)rootPath
{
    NSParameterAssert(rootPath);
    NSAssert(_tj_imageCacheRootPath == nil, @"You should not configure %@'s root path more than once.", NSStringFromClass([self class]));
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _tj_imageCacheRootPath = [rootPath copy];
    });
}

#pragma mark - Hashing

// Using 11 characters from the following table guarantees that we'll generate maximally unique keys that are also tagged pointer strings.
// Tagged pointers have memory and CPU performance benefits, so this is better than just using a plain ol' hex hash.
// I've omitted the "." and " " characters from this table to create "pleasant" filenames.
// For more info see https://mikeash.com/pyblog/friday-qa-2015-07-31-tagged-pointer-strings.html
static char *const kHashCharacterTable = "eilotrmapdnsIcufkMShjTRxgC4013";
static const NSUInteger kExpectedHashLength = 11;

NSString *TJImageCacheHash(NSString *string)
{
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([string UTF8String], (CC_LONG)string.length, result);
    
    return [NSString stringWithFormat:@"%c%c%c%c%c%c%c%c%c%c%c",
            kHashCharacterTable[result[0] % 30],
            kHashCharacterTable[result[1] % 30],
            kHashCharacterTable[result[2] % 30],
            kHashCharacterTable[result[3] % 30],
            kHashCharacterTable[result[4] % 30],
            kHashCharacterTable[result[5] % 30],
            kHashCharacterTable[result[6] % 30],
            kHashCharacterTable[result[7] % 30],
            kHashCharacterTable[result[8] % 30],
            kHashCharacterTable[result[9] % 30],
            kHashCharacterTable[result[10] % 30]
            ];
}

+ (NSString *)pathForURLString:(NSString *const)urlString
{
    return _pathForHash(TJImageCacheHash(urlString));
}

#pragma mark - Image Fetching

+ (IMAGE_CLASS *)imageAtURL:(NSString *const)urlString
{
    return [self imageAtURL:urlString depth:TJImageCacheDepthNetwork delegate:nil backgroundDecode:YES];
}

+ (IMAGE_CLASS *)imageAtURL:(NSString *const)urlString depth:(const TJImageCacheDepth)depth
{
    return [self imageAtURL:urlString depth:depth delegate:nil backgroundDecode:YES];
}

+ (IMAGE_CLASS *)imageAtURL:(NSString *const)urlString delegate:(const id<TJImageCacheDelegate>)delegate
{
    return [self imageAtURL:urlString depth:TJImageCacheDepthNetwork delegate:delegate backgroundDecode:YES];
}

+ (IMAGE_CLASS *)imageAtURL:(NSString *const)urlString depth:(const TJImageCacheDepth)depth delegate:(nullable const id<TJImageCacheDelegate>)delegate
{
    return [self imageAtURL:urlString depth:depth delegate:delegate backgroundDecode:YES];
}

+ (IMAGE_CLASS *)imageAtURL:(NSString *const)urlString depth:(const TJImageCacheDepth)depth delegate:(nullable const id<TJImageCacheDelegate>)delegate backgroundDecode:(const BOOL)backgroundDecode
{
    if (urlString.length == 0) {
        return nil;
    }
    
    // Attempt load from cache.
    
    __block IMAGE_CLASS *inMemoryImage = [_cache() objectForKey:urlString];
    
    // Attempt load from map table.
    
    if (!inMemoryImage) {
        _mapTableWithBlock(^(NSMapTable<NSString *, IMAGE_CLASS *> *const mapTable) {
            inMemoryImage = [mapTable objectForKey:urlString];
        }, NO);
        if (inMemoryImage) {
            // Propagate back into our cache.
            [_cache() setObject:inMemoryImage forKey:urlString cost:inMemoryImage.size.width * inMemoryImage.size.height];
        }
    }
    
    // Check if there's an existing disk/network request running for this image.
    if (!inMemoryImage && depth != TJImageCacheDepthMemory) {
        _requestDelegatesWithBlock(^(NSMutableDictionary<NSString *, NSHashTable<id<TJImageCacheDelegate>> *> *const requestDelegates) {
            BOOL loadAsynchronously = NO;
            NSHashTable *delegatesForRequest = [requestDelegates objectForKey:urlString];
            if (!delegatesForRequest) {
                delegatesForRequest = [NSHashTable weakObjectsHashTable];
                [requestDelegates setObject:delegatesForRequest forKey:urlString];
                loadAsynchronously = YES;
            }
            if (delegate) {
                [delegatesForRequest addObject:delegate];
            } else {
                // Since this request was started without a delegate, we add a no-op delegate to ensure that future calls to -cancelImageLoadForURL:delegate: won't inadvertently cancel it.
                static TJImageCacheNoOpDelegate *noOpDelegate;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    noOpDelegate = [TJImageCacheNoOpDelegate new];
                });
                [delegatesForRequest addObject:noOpDelegate];
            }
            
            // Attempt load from disk and network.
            if (loadAsynchronously) {
                static dispatch_queue_t asyncDispatchQueue;
                static NSFileManager *fileManager;
                static dispatch_once_t readOnceToken;
                dispatch_once(&readOnceToken, ^{
                    asyncDispatchQueue = dispatch_queue_create("TJImageCache async load queue", DISPATCH_QUEUE_CONCURRENT_WITH_AUTORELEASE_POOL);
                    fileManager = [NSFileManager defaultManager];
                });
                dispatch_async(asyncDispatchQueue, ^{
                    NSString *const hash = TJImageCacheHash(urlString);
                    NSURL *const url = [NSURL URLWithString:urlString];
                    const BOOL isFileURL = url.isFileURL;
                    NSString *const path = isFileURL ? url.path : _pathForHash(hash);
                    NSURL *const fileURL = isFileURL ? url : [NSURL fileURLWithPath:path isDirectory:NO];
                    if ([fileManager fileExistsAtPath:path]) {
                        _tryUpdateMemoryCacheAndCallDelegates(path, urlString, hash, backgroundDecode, 0);
                        
                        // Update last access date
                        [fileURL setResourceValue:[NSDate date] forKey:NSURLContentAccessDateKey error:nil];
                    } else if (depth == TJImageCacheDepthNetwork && !isFileURL && path) {
                        static NSURLSession *session;
                        static dispatch_once_t sessionOnceToken;
                        dispatch_once(&sessionOnceToken, ^{
                            // We use an ephemeral session since TJImageCache does memory and disk caching.
                            // Using NSURLCache would be redundant.
                            NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
                            config.waitsForConnectivity = YES;
                            config.timeoutIntervalForResource = 60;
                            session = [NSURLSession sessionWithConfiguration:config];
                        });
                        
                        NSMutableURLRequest *const request = [NSMutableURLRequest requestWithURL:url];
                        [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
                        
                        NSURLSessionDownloadTask *const task = [session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *networkError) {
                            dispatch_async(asyncDispatchQueue, ^{
                                BOOL validToProcess = location != nil && [response isKindOfClass:[NSHTTPURLResponse class]];
                                if (validToProcess) {
                                    NSString *contentType;
                                    static NSString *const kContentTypeResponseHeaderKey = @"Content-Type";
#if !defined(__IPHONE_13_0) || __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_13_0
                                    if (@available(iOS 13.0, *)) {
#endif
                                        // -valueForHTTPHeaderField: is more "correct" since it's case-insensitive, however it's only available in iOS 13+.
                                        contentType = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:kContentTypeResponseHeaderKey];
#if !defined(__IPHONE_13_0) || __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_13_0
                                    } else {
                                        contentType = [[(NSHTTPURLResponse *)response allHeaderFields] objectForKey:kContentTypeResponseHeaderKey];
                                    }
#endif
                                    validToProcess = [contentType hasPrefix:@"image/"];
                                }
                                
                                BOOL success;
                                if (validToProcess) {
                                    // Lazily generate the directory the first time it's written to if needed.
                                    static dispatch_once_t rootDirectoryOnceToken;
                                    dispatch_once(&rootDirectoryOnceToken, ^{
                                        if ([fileManager createDirectoryAtPath:_tj_imageCacheRootPath withIntermediateDirectories:YES attributes:nil error:nil]) {
                                            // Don't back up
                                            // https://developer.apple.com/library/ios/qa/qa1719/_index.html
                                            NSURL *const rootURL = _tj_imageCacheRootPath != nil ? [NSURL fileURLWithPath:_tj_imageCacheRootPath isDirectory:YES] : nil;
                                            [rootURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
                                        }
                                    });
                                    
                                    // Move resulting image into place.
                                    NSError *error;
                                    if ([fileManager moveItemAtURL:location toURL:fileURL error:&error]) {
                                        success = YES;
                                    } else {
                                        // Still consider this a success if the file already exists.
                                        success = error.code == NSFileWriteFileExistsError // https://apple.co/3vO2s0X
                                        && [error.domain isEqualToString:NSCocoaErrorDomain];
                                        NSAssert(!success, @"Loaded file that already exists! %@ -> %@", urlString, hash);
                                    }
                                } else {
                                    success = NO;
                                }
                                
                                if (success) {
                                    // Inform delegates about success
                                    _tryUpdateMemoryCacheAndCallDelegates(path, urlString, hash, backgroundDecode, response.expectedContentLength);
                                } else {
                                    // Inform delegates about failure
                                    _tryUpdateMemoryCacheAndCallDelegates(nil, urlString, hash, backgroundDecode, 0);
                                    if (location) {
                                        [fileManager removeItemAtURL:location error:nil];
                                    }
                                }
                                
                                _tasksForImageURLStringsWithBlock(^(NSMutableDictionary<NSString *,NSURLSessionDownloadTask *> *const tasks) {
                                    [tasks removeObjectForKey:urlString];
                                });
                            });
                        }];
                        
                        task.countOfBytesClientExpectsToSend = 0;
                        
                        _tasksForImageURLStringsWithBlock(^(NSMutableDictionary<NSString *,NSURLSessionDownloadTask *> *const tasks) {
                            [tasks setObject:task forKey:urlString];
                        });
                        
                        [task resume];
                    } else {
                        // Inform delegates about failure
                        _tryUpdateMemoryCacheAndCallDelegates(nil, urlString, hash, backgroundDecode, 0);
                    }
                });
            }
        }, NO);
    }
    
    return inMemoryImage;
}

+ (void)cancelImageLoadForURL:(NSString *const)urlString delegate:(const id<TJImageCacheDelegate>)delegate policy:(const TJImageCacheCancellationPolicy)policy
{
    _requestDelegatesWithBlock(^(NSMutableDictionary<NSString *,NSHashTable<id<TJImageCacheDelegate>> *> *const requestDelegates) {
        BOOL cancelTask = NO;
        NSHashTable *const delegates = [requestDelegates objectForKey:urlString];
        if (delegates) {
            [delegates removeObject:delegate];
            if ([delegates tj_isEmpty]) {
                cancelTask = YES;
            }
        }
        if (cancelTask && policy != TJImageCacheCancellationPolicyImageProcessing) {
            // NOTE: Could potentially use -getTasksWithCompletionHandler: instead, however that's async.
            _tasksForImageURLStringsWithBlock(^(NSMutableDictionary<NSString *,NSURLSessionDataTask *> *const tasks) {
                NSURLSessionTask *const task = tasks[urlString];
                if (task) {
                    switch (policy) {
                        case TJImageCacheCancellationPolicyBeforeResponse:
                            if (task.response) {
                                break;
                            }
                        case TJImageCacheCancellationPolicyBeforeBody:
                            if (task.countOfBytesReceived > 0) {
                                break;
                            }
                        case TJImageCacheCancellationPolicyUnconditional:
                            [task cancel];
                            [requestDelegates removeObjectForKey:urlString];
                            break;
                        case TJImageCacheCancellationPolicyImageProcessing:
                            NSAssert(NO, @"This should never be reached");
                            break;
                    }
                }
            });
        }
    }, NO);
}

#pragma mark - Cache Checking

+ (void)getDiskCacheSize:(void (^const)(long long diskCacheSize))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        long long fileSize = 0;
        NSDirectoryEnumerator *const enumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:_rootPath() isDirectory:YES] includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:nil];
        for (NSURL *url in enumerator) {
            NSNumber *fileSizeNumber;
            [url getResourceValue:&fileSizeNumber forKey:NSURLTotalFileAllocatedSizeKey error:nil];
            fileSize += fileSizeNumber.unsignedLongLongValue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(fileSize);
            _setBaseCacheSize(fileSize);
        });
    });
}

#pragma mark - Cache Manipulation

+ (void)dumpMemoryCache
{
    [_cache() removeAllObjects];
}

#pragma mark - Cache Auditing

+ (void)auditCacheWithBlock:(BOOL (^const)(NSString *hashedURL, NSURL *fileURL, long long fileSize))block
               propertyKeys:(NSArray<NSURLResourceKey> *const)inPropertyKeys
            completionBlock:(const dispatch_block_t)completionBlock
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSFileManager *const fileManager = [NSFileManager defaultManager];
        NSArray *const propertyKeys = inPropertyKeys ? [inPropertyKeys arrayByAddingObject:NSURLTotalFileAllocatedSizeKey] : @[NSURLTotalFileAllocatedSizeKey];
        NSDirectoryEnumerator *const enumerator = [fileManager enumeratorAtURL:[NSURL fileURLWithPath:_rootPath() isDirectory:NO]
                                                    includingPropertiesForKeys:propertyKeys
                                                                       options:0
                                                                  errorHandler:nil];
        long long totalFileSize = 0;
        for (NSURL *url in enumerator) {
            @autoreleasepool {
                NSNumber *fileSizeNumber;
                [url getResourceValue:&fileSizeNumber forKey:NSURLTotalFileAllocatedSizeKey error:nil];
                const unsigned long long fileSize = fileSizeNumber.unsignedLongValue;
                BOOL remove;
                NSString *const file = url.lastPathComponent;
                if (file.length == kExpectedHashLength) {
                    __block BOOL isInUse = NO;
                    _mapTableWithBlock(^(NSMapTable<NSString *, IMAGE_CLASS *> *const mapTable) {
                        isInUse = [mapTable objectForKey:file] != nil;
                    }, NO);
                    remove = !isInUse && !block(file, url, fileSize);
                } else {
                    remove = YES;
                }
                BOOL wasRemoved;
                if (remove) {
                    wasRemoved = [fileManager removeItemAtPath:_pathForHash(file) error:nil];
                } else {
                    wasRemoved = NO;
                }
                if (!wasRemoved) {
                    totalFileSize += fileSize;
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock();
            }
            _setBaseCacheSize(totalFileSize);
        });
    });
}

#pragma mark - Private

static NSString *_rootPath(void)
{
    NSCAssert(_tj_imageCacheRootPath != nil, @"You should configure %@'s root path before attempting to use it.", NSStringFromClass([TJImageCache class]));
    return _tj_imageCacheRootPath;
}

static NSString *_pathForHash(NSString *const hash)
{
    NSString *path = _rootPath();
    if (hash) {
        path = [path stringByAppendingPathComponent:hash];
    }
    return path;
}

/// Keys are image URL strings, NOT hashes
static NSCache<NSString *, IMAGE_CLASS *> *_cache(void)
{
    static NSCache<NSString *, IMAGE_CLASS *> *cache;
    static dispatch_once_t token;
    
    dispatch_once(&token, ^{
        cache = [NSCache new];
    });
    
    return cache;
}

/// Every image maps to two keys in this map table.
/// { image URL string -> image,
///   image URL string hash -> image }
/// Both keys are used so that we can easily query for membership based on either URL (used for in-memory lookups) or hash (used for on-disk lookups)
static void _mapTableWithBlock(void (^block)(NSMapTable<NSString *, IMAGE_CLASS *> *const mapTable), const BOOL blockIsWriteOnly)
{
    static NSMapTable<NSString *, IMAGE_CLASS *> *mapTable;
    static dispatch_once_t token;
    static dispatch_queue_t queue;
    
    dispatch_once(&token, ^{
        mapTable = [NSMapTable strongToWeakObjectsMapTable];
        queue = dispatch_queue_create("TJImageCache map table queue", DISPATCH_QUEUE_CONCURRENT);
    });
    
    if (blockIsWriteOnly) {
        dispatch_barrier_async(queue, ^{
            block(mapTable);
        });
    } else {
        dispatch_sync(queue, ^{
            block(mapTable);
        });
    }
}

/// Keys are image URL strings
static void _requestDelegatesWithBlock(void (^block)(NSMutableDictionary<NSString *, NSHashTable<id<TJImageCacheDelegate>> *> *const requestDelegates), const BOOL sync)
{
    static NSMutableDictionary<NSString *, NSHashTable<id<TJImageCacheDelegate>> *> *requests;
    static dispatch_once_t token;
    static dispatch_queue_t queue;
    
    dispatch_once(&token, ^{
        requests = [NSMutableDictionary new];
        queue = dispatch_queue_create("TJImageCache._requestDelegatesWithBlock", DISPATCH_QUEUE_SERIAL);
    });
    
    if (sync) {
        dispatch_sync(queue, ^{
            block(requests);
        });
    } else {
        dispatch_async(queue, ^{
            block(requests);
        });
    }
}

/// Keys are image URL strings
static void _tasksForImageURLStringsWithBlock(void (^block)(NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *const tasks))
{
    static NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *tasks;
    static dispatch_once_t token;
    static dispatch_queue_t queue;
    
    dispatch_once(&token, ^{
        tasks = [NSMutableDictionary new];
        queue = dispatch_queue_create("TJImageCache._tasksForImageURLStringsWithBlock", DISPATCH_QUEUE_SERIAL);
    });
    
    dispatch_sync(queue, ^{
        block(tasks);
    });
}

static void _tryUpdateMemoryCacheAndCallDelegates(NSString *const path, NSString *const urlString, NSString *const hash, const BOOL backgroundDecode, const long long size)
{
    __block NSHashTable *delegatesForRequest = nil;
    _requestDelegatesWithBlock(^(NSMutableDictionary<NSString *, NSHashTable<id<TJImageCacheDelegate>> *> *const requestDelegates) {
        delegatesForRequest = [requestDelegates objectForKey:urlString];
        [requestDelegates removeObjectForKey:urlString];
    }, YES);
    
    const BOOL canProcess = ![delegatesForRequest tj_isEmpty];
    
    IMAGE_CLASS *image = nil;
    if (canProcess) {
        if (path) {
            if (backgroundDecode) {
                image = _predrawnImageFromPath(path);
            }
            if (!image) {
                image = [IMAGE_CLASS imageWithContentsOfFile:path];
            }
        }
        if (image) {
            [_cache() setObject:image forKey:urlString cost:image.size.width * image.size.height];
            _mapTableWithBlock(^(NSMapTable<NSString *, IMAGE_CLASS *> *const mapTable) {
                [mapTable setObject:image forKey:hash];
                [mapTable setObject:image forKey:urlString];
            }, YES);
        }
    }
    // else { Skip drawing / updating cache / calling delegates since the result wouldn't be used }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id<TJImageCacheDelegate> delegate in delegatesForRequest) {
            if (image) {
                [delegate didGetImage:image atURL:urlString];
            } else if ([delegate respondsToSelector:@selector(didFailToGetImageAtURL:)]) {
                [delegate didFailToGetImageAtURL:urlString];
            }
        }
        _modifyDeltaSize(size);
    });
    
    // Per this WWDC talk, dump as much memory as possible when entering the background to avoid jetsam.
    // https://developer.apple.com/videos/play/wwdc2020/10078/?t=333
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void (^emptyCacheBlock)(NSNotification *) = ^(NSNotification * _Nonnull note) {
            [TJImageCache dumpMemoryCache];
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:emptyCacheBlock];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSExtensionHostDidEnterBackgroundNotification object:nil queue:nil usingBlock:emptyCacheBlock];
    });
}

// Modified version of https://github.com/Flipboard/FLAnimatedImage/blob/master/FLAnimatedImageDemo/FLAnimatedImage/FLAnimatedImage.m#L641
static IMAGE_CLASS *_predrawnImageFromPath(NSString *const path)
{
#if defined(__IPHONE_15_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_15_0
#if !defined(__IPHONE_15_0) || __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_15_0
    if (@available(iOS 15.0, *))
#endif
    {
        return [[UIImage imageWithContentsOfFile:path] imageByPreparingForDisplay];
    }
#endif
    
#if !defined(__IPHONE_15_0) || __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_15_0
    // Always use a device RGB color space for simplicity and predictability what will be going on.
    static CGColorSpaceRef colorSpaceDeviceRGBRef;
    static CFDictionaryRef options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpaceDeviceRGBRef = CGColorSpaceCreateDeviceRGB();
        options = (__bridge_retained CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: (__bridge id)kCFBooleanFalse};
    });
    
    const CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path isDirectory:NO], nil);
    const CGImageRef image = CGImageSourceCreateImageAtIndex(imageSource, 0, options);
    
    if (imageSource) {
        CFRelease(imageSource);
    }
    
    if (!image) {
        return nil;
    }
    
    // "In iOS 4.0 and later, and OS X v10.6 and later, you can pass NULL if you want Quartz to allocate memory for the bitmap." (source: docs)
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    
    // RGB+A
    const size_t bytesPerRow = width << 2;
    
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(image);
    // If the alpha info doesn't match to one of the supported formats (see above), pick a reasonable supported one.
    // "For bitmaps created in iOS 3.2 and later, the drawing environment uses the premultiplied ARGB format to store the bitmap data." (source: docs)
    switch (alphaInfo) {
        case kCGImageAlphaNone:
        case kCGImageAlphaOnly:
        case kCGImageAlphaFirst:
            alphaInfo = kCGImageAlphaNoneSkipFirst;
            break;
        case kCGImageAlphaLast:
            alphaInfo = kCGImageAlphaNoneSkipLast;
            break;
        default:
            break;
    }
    
    // Create our own graphics context to draw to; `UIGraphicsGetCurrentContext`/`UIGraphicsBeginImageContextWithOptions` doesn't create a new context but returns the current one which isn't thread-safe (e.g. main thread could use it at the same time).
    // Note: It's not worth caching the bitmap context for multiple frames ("unique key" would be `width`, `height` and `hasAlpha`), it's ~50% slower. Time spent in libRIP's `CGSBlendBGRA8888toARGB8888` suddenly shoots up -- not sure why.
    
    const CGContextRef bitmapContextRef = CGBitmapContextCreate(NULL, width, height, CHAR_BIT, bytesPerRow, colorSpaceDeviceRGBRef, kCGBitmapByteOrderDefault | alphaInfo);
    // Early return on failure!
    if (!bitmapContextRef) {
        NSCAssert(NO, @"Failed to `CGBitmapContextCreate` with color space %@ and parameters (width: %zu height: %zu bitsPerComponent: %zu bytesPerRow: %zu) for image %@", colorSpaceDeviceRGBRef, width, height, (size_t)CHAR_BIT, bytesPerRow, image);
        CGImageRelease(image);
        return nil;
    }
    
    // Draw image in bitmap context and create image by preserving receiver's properties.
    CGContextDrawImage(bitmapContextRef, CGRectMake(0.0, 0.0, width, height), image);
    const CGImageRef predrawnImageRef = CGBitmapContextCreateImage(bitmapContextRef);
    IMAGE_CLASS *const predrawnImage = [IMAGE_CLASS imageWithCGImage:predrawnImageRef];
    CGImageRelease(image);
    CGImageRelease(predrawnImageRef);
    CGContextRelease(bitmapContextRef);
    
    return predrawnImage;
#endif
}

+ (void)computeDiskCacheSizeIfNeeded
{
    if (_tj_imageCacheBaseSize == nil) {
        [self getDiskCacheSize:^(long long diskCacheSize) {
            // intentional no-op, cache size is set as a side effect of +getDiskCacheSize: running.
        }];
    }
}

+ (NSNumber *)approximateDiskCacheSize
{
    return _tj_imageCacheApproximateCacheSize;
}

static void _setApproximateCacheSize(const long long cacheSize)
{
    static NSString *key;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        key = NSStringFromSelector(@selector(approximateDiskCacheSize));
    });
    if (cacheSize != _tj_imageCacheApproximateCacheSize.longLongValue) {
        [TJImageCache willChangeValueForKey:key];
        _tj_imageCacheApproximateCacheSize = @(cacheSize);
        [TJImageCache didChangeValueForKey:key];
    }
}

static void _setBaseCacheSize(const long long diskCacheSize)
{
    _tj_imageCacheBaseSize = @(diskCacheSize);
    _tj_imageCacheDeltaSize = 0;
    _setApproximateCacheSize(diskCacheSize);
}

static void _modifyDeltaSize(const long long delta)
{
    // We don't track in-memory deltas unless a base size has been computed.
    if (_tj_imageCacheBaseSize != nil) {
        _tj_imageCacheDeltaSize += delta;
        _setApproximateCacheSize(_tj_imageCacheBaseSize.longLongValue + _tj_imageCacheDeltaSize);
    }
}

@end
