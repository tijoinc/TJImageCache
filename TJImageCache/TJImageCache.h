// TJImageCache
// By Tim Johnsen

// NOTE: To use in OS X, you should import AppKit and change IMAGE_CLASS to NSImage
#import <UIKit/UIKit.h>
#define IMAGE_CLASS UIImage

typedef NS_CLOSED_ENUM(NSUInteger, TJImageCacheDepth) {
    TJImageCacheDepthMemory,
    TJImageCacheDepthDisk,
    TJImageCacheDepthNetwork
};

typedef NS_CLOSED_ENUM(NSUInteger, TJImageCacheCancellationPolicy) {
    TJImageCacheCancellationPolicyImageProcessing,  // Only cancels image decompression, image is still downloaded
    TJImageCacheCancellationPolicyBeforeResponse,   // Cancels request if a response hasn't yet been received
    TJImageCacheCancellationPolicyBeforeBody,       // Cancels request if a body hasn't yet been received
    TJImageCacheCancellationPolicyUnconditional,    // Cancels request unconditionally
};

NS_ASSUME_NONNULL_BEGIN

@protocol TJImageCacheDelegate <NSObject>

- (void)didGetImage:(IMAGE_CLASS *)image atURL:(NSString *)url;

@optional

- (void)didFailToGetImageAtURL:(NSString *)url;

@end

extern NSString *TJImageCacheHash(NSString *string);

@interface TJImageCache : NSObject

+ (void)configureWithRootPath:(NSString *const)rootPath;

+ (NSString *)pathForURLString:(NSString *const)urlString;

+ (nullable IMAGE_CLASS *)imageAtURL:(NSString *const)url depth:(const TJImageCacheDepth)depth delegate:(nullable const id<TJImageCacheDelegate>)delegate backgroundDecode:(const BOOL)backgroundDecode;
+ (nullable IMAGE_CLASS *)imageAtURL:(NSString *const)url depth:(const TJImageCacheDepth)depth delegate:(nullable const id<TJImageCacheDelegate>)delegate;
+ (nullable IMAGE_CLASS *)imageAtURL:(NSString *const)url delegate:(nullable const id<TJImageCacheDelegate>)delegate;
+ (nullable IMAGE_CLASS *)imageAtURL:(NSString *const)url depth:(const TJImageCacheDepth)depth;
+ (nullable IMAGE_CLASS *)imageAtURL:(NSString *const)url;

+ (void)cancelImageLoadForURL:(NSString *const)url delegate:(const id<TJImageCacheDelegate>)delegate policy:(const TJImageCacheCancellationPolicy)policy;

+ (void)dumpMemoryCache;
+ (void)getDiskCacheSize:(void (^const)(long long diskCacheSize))completion;

+ (void)auditCacheWithBlock:(BOOL (^const)(NSString *hashedURL, NSURL *fileURL, long long fileSize))block // return YES to preserve the image, return NO to delete it
               propertyKeys:(nullable NSArray<NSURLResourceKey> *)propertyKeys
            completionBlock:(nullable dispatch_block_t)completionBlock;

+ (void)computeDiskCacheSizeIfNeeded;
/// Will be @c nil until @c +computeDiskCacheSizeIfNeeded, @c +getDiskCacheSize:, or one of the cache auditing methods is called once, then it will update automatically as the cache changes.
/// Observe using KVO.
@property (nonatomic, readonly, class) NSNumber *approximateDiskCacheSize;

@end

NS_ASSUME_NONNULL_END
