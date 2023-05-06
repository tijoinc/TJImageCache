//
//  TJProgressiveImageView.m
//  OpenerCore
//
//  Created by Tim Johnsen on 1/30/20.
//  Copyright © 2020 tijo. All rights reserved.
//

#import "TJProgressiveImageView.h"

__attribute__((objc_direct_members))
@interface TJProgressiveImageView () <TJImageCacheDelegate> {
    NSInteger _currentImageURLStringIndex;
}

@end

@implementation TJProgressiveImageView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        _currentImageURLStringIndex = NSNotFound;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    if (!self.image) {
        NSOrderedSet<NSString *> *imageURLStrings = self.imageURLStrings;
        self.imageURLStrings = nil;
        self.imageURLStrings = imageURLStrings;
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    if (!self.window) {
        self.image = nil;
    }
}

- (void)setImageURLStrings:(NSOrderedSet<NSString *> *)imageURLStrings
{
    [self setImageURLStrings:imageURLStrings secondaryImageDepth:TJImageCacheDepthDisk];
}

- (void)setImageURLStrings:(NSOrderedSet<NSString *> * _Nullable)imageURLStrings secondaryImageDepth:(const TJImageCacheDepth)secondaryImageDepth
{
    if (imageURLStrings != _imageURLStrings && ![imageURLStrings isEqual:_imageURLStrings]) {
        NSOrderedSet<NSString *> *const priorImageURLStrings = _imageURLStrings;
        NSString *const priorImageURLString = _currentImageURLStringIndex != NSNotFound ? [_imageURLStrings objectAtIndex:_currentImageURLStringIndex] : nil;
        _imageURLStrings = imageURLStrings;
        _currentImageURLStringIndex = _imageURLStrings == nil || priorImageURLString == nil ? NSNotFound : [_imageURLStrings indexOfObject:priorImageURLString];
        
        if (_currentImageURLStringIndex != 0) {
            [_imageURLStrings enumerateObjectsUsingBlock:^(NSString * _Nonnull urlString, NSUInteger idx, BOOL * _Nonnull stop) {
                if (idx >= _currentImageURLStringIndex) {
                    // Don't attempt to load images beyond the best one we already have.
                    *stop = YES;
                } else {
                    // Load image 0 from network, all others loaded at secondaryImageDepth.
                    const TJImageCacheDepth depth = idx == 0 ? TJImageCacheDepthNetwork : secondaryImageDepth;
                    UIImage *const image = [TJImageCache imageAtURL:urlString depth:depth delegate:self backgroundDecode:YES];
                    if (image) {
                        _currentImageURLStringIndex = idx;
                        self.image = image;
                        *stop = YES;
                    }
                }
            }];
            
            if (_currentImageURLStringIndex == NSNotFound) {
                self.image = nil;
            }
        }
        
        for (NSString *str in priorImageURLStrings) {
            if (![imageURLStrings containsObject:str]) {
                [TJImageCache cancelImageLoadForURL:str delegate:self policy:TJImageCacheCancellationPolicyImageProcessing];
            }
        }
    }
}

- (void)cancelImageLoadsWithPolicy:(const TJImageCacheCancellationPolicy)policy
{
    [self.imageURLStrings enumerateObjectsUsingBlock:^(NSString * _Nonnull urlString, NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx < _currentImageURLStringIndex || _currentImageURLStringIndex == NSNotFound) {
            [TJImageCache cancelImageLoadForURL:urlString delegate:self policy:policy];
        } else {
            *stop = YES;
        }
    }];
}

#pragma mark - TJImageCacheDelegate

- (void)didGetImage:(UIImage *)image atURL:(NSString *)url
{
    __block BOOL cancelLowPriImages = NO;
    [_imageURLStrings enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx < _currentImageURLStringIndex) {
            if ([obj isEqualToString:url]) {
                _currentImageURLStringIndex = idx;
                self.image = image;
                cancelLowPriImages = YES;
            }
        } else if (cancelLowPriImages) {
            // Cancel any lower priority images
            [TJImageCache cancelImageLoadForURL:obj delegate:self policy:TJImageCacheCancellationPolicyBeforeBody];
        } else {
            *stop = YES;
        }
    }];
}

@end
