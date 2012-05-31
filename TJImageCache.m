// TJImageCache
// By Tim Johnsen

#import "TJImageCache.h"
#import <CommonCrypto/CommonDigest.h>

#pragma mark -
#pragma mark TJImageCacheConnection

@interface TJImageCacheConnection : NSURLConnection

@property (nonatomic, retain) NSMutableData *data;
@property (readonly) NSMutableSet *delegates;
@property (nonatomic, retain) NSString *url;

@end

@implementation TJImageCacheConnection : NSURLConnection

@synthesize data = _data;
@synthesize delegates = _delegates;
@synthesize url = _url;

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate {
	if ((self = [super initWithRequest:request delegate:delegate])) {
		_delegates = [[NSMutableSet alloc] init];
	}
	
	return self;
}

- (void)dealloc {
	[_data release];
	[_delegates release];
	[_url release];
	
	[super dealloc];
}

@end

#pragma mark -
#pragma mark TJImageCache

@interface TJImageCache ()

+ (NSString *)_pathForURL:(NSString *)url;

+ (NSMutableDictionary *)_requests;
+ (NSRecursiveLock *)_requestLock;
+ (NSCache *)_cache;

+ (NSOperationQueue *)_readQueue;
+ (NSOperationQueue *)_writeQueue;

@end

@implementation TJImageCache

#pragma mark -
#pragma mark Hashing

+ (NSString *)hash:(NSString *)string {
	const char* str = [string UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, strlen(str), result);
	
    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];
    for(int i = 0; i<CC_MD5_DIGEST_LENGTH; i++) {
        [ret appendFormat:@"%02x",result[i]];
    }
    return ret;
}

#pragma mark -
#pragma mark Image Fetching

+ (UIImage *)imageAtURL:(NSString *)url delegate:(id<TJImageCacheDelegate>)delegate {
	return [self imageAtURL:url depth:TJImageCacheDepthInternet delegate:delegate];
}

+ (UIImage *)imageAtURL:(NSString *)url depth:(TJImageCacheDepth)depth {
	return [self imageAtURL:url depth:depth delegate:nil];
}

+ (UIImage *)imageAtURL:(NSString *)url {
	return [self imageAtURL:url depth:TJImageCacheDepthInternet delegate:nil];
}

+ (UIImage *)imageAtURL:(NSString *)url depth:(TJImageCacheDepth)depth delegate:(id<TJImageCacheDelegate>)delegate {
	
	if (!url) {
		return nil;
	}
	
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		BOOL isDir = NO;
		if (!([[NSFileManager defaultManager] fileExistsAtPath:[TJImageCache _pathForURL:nil] isDirectory:&isDir] && isDir)) {
			[[NSFileManager defaultManager] createDirectoryAtPath:[TJImageCache _pathForURL:nil] withIntermediateDirectories:YES attributes:nil error:nil];
		}
	});
	
	// Load from memory
	
	NSString *hash = [TJImageCache hash:url];
	__block UIImage *image = [[TJImageCache _cache] objectForKey:hash];
	
	// Load from disk
	
	if (!image && depth != TJImageCacheDepthMemory) {
		
		[[TJImageCache _readQueue] addOperationWithBlock:^{
			NSString *path = [TJImageCache _pathForURL:url];
			image = [UIImage imageWithContentsOfFile:path];
			
			if (image) {
				// update last access date
				[[NSFileManager defaultManager] setAttributes:[NSDictionary dictionaryWithObject:[NSDate date] forKey:NSFileModificationDate] ofItemAtPath:path error:nil];
				
				// add to in-memory cache
				[[TJImageCache _cache] setObject:image forKey:hash];
				
				// tell delegate about success
				if ([delegate respondsToSelector:@selector(didGetImage:atURL:)]) {
					[image retain];
					dispatch_async(dispatch_get_main_queue(), ^{
						[delegate didGetImage:image atURL:url];
						[image release];
					});
				}
			} else {
				if (depth == TJImageCacheDepthInternet) {
					
					// setup or add to delegate ball wrapped in locks...
					
					dispatch_async(dispatch_get_main_queue(), ^{
						
						// Load from the interwebs using NSURLConnection delegate
						
						[[TJImageCache _requestLock] lock];
						
						if ([[TJImageCache _requests] objectForKey:hash]) {
							if (delegate) {
								TJImageCacheConnection *connection = [[TJImageCache _requests] objectForKey:hash];
								if (delegate) {
									[connection.delegates addObject:delegate];
								}
							}
						} else {
							TJImageCacheConnection *connection = [[TJImageCacheConnection alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]] delegate:[TJImageCache class]];
							connection.url = [[url copy] autorelease];
							if (delegate) {
								[connection.delegates addObject:delegate];
							}
							
							[[TJImageCache _requests] setObject:connection forKey:hash];
							[connection release];
						}
						
						[[TJImageCache _requestLock] unlock];
					});
				} else {
					// tell delegate about failure
					if ([delegate respondsToSelector:@selector(didFailToGetImageAtURL:)]) {
						dispatch_async(dispatch_get_main_queue(), ^{
							[delegate didFailToGetImageAtURL:url];
						});
					}
				}
			}
		}];
	}
	
	return image;
}

#pragma mark -
#pragma mark Cache Checking

+ (TJImageCacheDepth)depthForImageAtURL:(NSString *)url {
	
	if ([[TJImageCache _cache] objectForKey:[TJImageCache hash:url]]) {
		return TJImageCacheDepthMemory;
	}
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:[TJImageCache _pathForURL:url]]) {
		return TJImageCacheDepthDisk;
	}
	
	return TJImageCacheDepthInternet;
}

#pragma mark -
#pragma mark Cache Manipulation

+ (void)removeImageAtURL:(NSString *)url {
	[[TJImageCache _cache] removeObjectForKey:[TJImageCache hash:url]];
	
	[[NSFileManager defaultManager] removeItemAtPath:[TJImageCache _pathForURL:url] error:nil];
}

+ (void)dumpDiskCache {
	[[NSFileManager defaultManager] removeItemAtPath:[TJImageCache _pathForURL:nil] error:nil];
	[[NSFileManager defaultManager] createDirectoryAtPath:[TJImageCache _pathForURL:nil] withIntermediateDirectories:YES attributes:nil error:nil];
}

+ (void)dumpMemoryCache {
	[[TJImageCache _cache] removeAllObjects];
}

#pragma mark -
#pragma mark Cache Auditing

+ (void)auditCacheWithBlock:(BOOL (^)(NSString *hashedURL, NSDate *lastAccess, NSDate *createdDate))block {
	dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		NSString *basePath = [TJImageCache _pathForURL:nil];
		NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:nil];

		for (NSString *file in files) {
			@autoreleasepool {
				NSString *path = [basePath stringByAppendingPathComponent:file];
				NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
				NSDate *createdDate = [attributes objectForKey:NSFileCreationDate];
				NSDate *lastAccess = [attributes objectForKey:NSFileModificationDate];
				if (!block(file, lastAccess, createdDate)) {
					[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
				}
			}
		}
	});
}

+ (void)auditCacheRemovingFilesOlderThanDate:(NSDate *)date {
	[TJImageCache auditCacheWithBlock:^BOOL(NSString *hashedURL, NSDate *lastAccess, NSDate *createdDate){
		return ([createdDate compare:date] != NSOrderedAscending);
	}];
}

+ (void)auditCacheRemovingFilesLastAccessedBeforeDate:(NSDate *)date {
	[TJImageCache auditCacheWithBlock:^BOOL(NSString *hashedURL, NSDate *lastAccess, NSDate *createdDate){
		return ([lastAccess compare:date] != NSOrderedAscending);
	}];
}

#pragma mark -
#pragma mark NSURLConnectionDelegate

+ (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	[(TJImageCacheConnection *)connection setData:[NSMutableData data]];
}

+ (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)theData {
	[[(TJImageCacheConnection *)connection data] appendData:theData];
}

+ (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	[[TJImageCache _requestLock] lock];
	
	// process image
	UIImage *image = [UIImage imageWithData:[(TJImageCacheConnection *)connection data]];
	
	if (image) {
		
		NSString *url = [(TJImageCacheConnection *)connection url];
	
		// Cache in Memory
		[[TJImageCache _cache] setObject:image forKey:[TJImageCache hash:url]];
		
		// Cache to Disk
		[[TJImageCache _writeQueue] addOperationWithBlock:^{
			[UIImagePNGRepresentation(image) writeToFile:[TJImageCache _pathForURL:url] atomically:YES];
		}];
		
		// Inform Delegates
		for (id delegate in [(TJImageCacheConnection *)connection delegates]) {
			if ([delegate respondsToSelector:@selector(didGetImage:atURL:)]) {
				[delegate didGetImage:image atURL:url];
			}
		}
		
		// Remove the connection
		[[TJImageCache _requests] removeObjectForKey:[TJImageCache hash:url]];
		
	} else {
		[TJImageCache performSelector:@selector(connection:didFailWithError:) withObject:connection withObject:nil];
	}
	
	[[TJImageCache _requestLock] unlock];
}

+ (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	[[TJImageCache _requestLock] lock];
	
	NSString *url = [(TJImageCacheConnection *)connection url];
	
	// Inform Delegates
	for (id delegate in [(TJImageCacheConnection *)connection delegates]) {
		if ([delegate respondsToSelector:@selector(didFailToGetImageAtURL:)]) {
			[delegate didFailToGetImageAtURL:url];
		}
	}
	
	// Remove the connection
	[[TJImageCache _requests] removeObjectForKey:[TJImageCache hash:url]];
	
	[[TJImageCache _requestLock] unlock];
}

#pragma mark -
#pragma mark Private

+ (NSString *)_pathForURL:(NSString *)url {
	static NSString *path = nil;
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		path = [[[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"Caches/TJImageCache"] retain];
	});
	
	if (url) {
		return [path stringByAppendingPathComponent:[TJImageCache hash:url]];
	}
	return path;
}

+ (NSMutableDictionary *)_requests {
	static NSMutableDictionary *requests = nil;
	static dispatch_once_t token;
	
	dispatch_once(&token, ^{
		requests = [[NSMutableDictionary alloc] init];
	});
	
	return requests;
}

+ (NSRecursiveLock *)_requestLock {
	static NSRecursiveLock *lock = nil;
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		lock = [[NSRecursiveLock alloc] init];
	});
	
	return lock;
}

+ (NSCache *)_cache {
	static NSCache *cache = nil;
	static dispatch_once_t token;
	
	dispatch_once(&token, ^{
		cache = [[NSCache alloc] init];
		[cache setCountLimit:100];
	});
	
	return cache;
}

+ (NSOperationQueue *)_readQueue {
	static NSOperationQueue *queue = nil;
	static dispatch_once_t token;
	
	dispatch_once(&token, ^{
		queue = [[NSOperationQueue alloc] init];
		[queue setMaxConcurrentOperationCount:4];
	});
	
	return queue;
}

+ (NSOperationQueue *)_writeQueue {
	static NSOperationQueue *queue = nil;
	static dispatch_once_t token;
	
	dispatch_once(&token, ^{
		queue = [[NSOperationQueue alloc] init];
		[queue setMaxConcurrentOperationCount:4];
	});
	
	return queue;
}

@end