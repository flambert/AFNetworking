// UIImageView+AFNetworking.m
//
// Copyright (c) 2011 Gowalla (http://gowalla.com/)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#if __IPHONE_OS_VERSION_MIN_REQUIRED
#import "UIImageView+AFNetworking.h"

@interface AFImageCache : NSCache
@property (nonatomic, assign) CGFloat imageScale;

- (UIImage *)cachedImageForURL:(NSURL *)url
                     cacheName:(NSString *)cacheName;

- (void)cacheImageData:(NSData *)imageData
                forURL:(NSURL *)url
             cacheName:(NSString *)cacheName;

static inline UIImage * resizeImageToFitSize(UIImage *image, CGSize fitSize);

@end

#pragma mark -

static char kAFImageRequestOperationObjectKey;

@interface UIImageView (_AFNetworking)
@property (readwrite, nonatomic, retain, setter = af_setImageRequestOperation:) AFImageRequestOperation *af_imageRequestOperation;
@end

@implementation UIImageView (_AFNetworking)
@dynamic af_imageRequestOperation;
@end

#pragma mark -

@implementation UIImageView (AFNetworking)

- (AFHTTPRequestOperation *)af_imageRequestOperation {
    return (AFHTTPRequestOperation *)objc_getAssociatedObject(self, &kAFImageRequestOperationObjectKey);
}

- (void)af_setImageRequestOperation:(AFImageRequestOperation *)imageRequestOperation {
    objc_setAssociatedObject(self, &kAFImageRequestOperationObjectKey, imageRequestOperation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (NSOperationQueue *)af_sharedImageRequestOperationQueue {
    static NSOperationQueue *_af_imageRequestOperationQueue = nil;
    
    if (!_af_imageRequestOperationQueue) {
        _af_imageRequestOperationQueue = [[NSOperationQueue alloc] init];
        [_af_imageRequestOperationQueue setMaxConcurrentOperationCount:8];
    }
    
    return _af_imageRequestOperationQueue;
}

+ (AFImageCache *)af_sharedImageCache {
    static AFImageCache *_af_imageCache = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _af_imageCache = [[AFImageCache alloc] init];
    });
    
    return _af_imageCache;
}

#pragma mark -

- (void)setImageWithURL:(NSURL *)url {
    [self setImageWithURL:url placeholderImage:nil scaledToSize:CGSizeZero];
}

- (void)setImageWithURL:(NSURL *)url
           scaledToSize:(CGSize)size {
    [self setImageWithURL:url placeholderImage:nil scaledToSize:size];
}

- (void)setImageWithURL:(NSURL *)url 
       placeholderImage:(UIImage *)placeholderImage {
    [self setImageWithURL:url placeholderImage:placeholderImage scaledToSize:CGSizeZero];
}

- (void)setImageWithURL:(NSURL *)url 
       placeholderImage:(UIImage *)placeholderImage
           scaledToSize:(CGSize)size
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30.0];
    [request setHTTPShouldHandleCookies:NO];
    [request setHTTPShouldUsePipelining:YES];
    
    [self setImageWithURLRequest:request placeholderImage:placeholderImage scaledToSize:size success:nil failure:nil];
}

- (void)setImageWithURLRequest:(NSURLRequest *)urlRequest 
              placeholderImage:(UIImage *)placeholderImage 
                       success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image))success
                       failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error))failure {
    [self setImageWithURLRequest:urlRequest placeholderImage:placeholderImage scaledToSize:CGSizeZero success:success failure:failure];
}

- (void)setImageWithURLRequest:(NSURLRequest *)urlRequest 
              placeholderImage:(UIImage *)placeholderImage 
                  scaledToSize:(CGSize)size 
                       success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image))success
                       failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error))failure
{
    if (![urlRequest URL] || (![self.af_imageRequestOperation isCancelled] && [[urlRequest URL] isEqual:[[self.af_imageRequestOperation request] URL]])) {
        return;
    } else {
        [self cancelImageRequestOperation];
    }
    
    NSString* cacheName = nil;
    if (CGSizeEqualToSize(size, CGSizeZero) == NO)
        cacheName = NSStringFromCGSize(size);
    
    UIImage *cachedImage = [[[self class] af_sharedImageCache] cachedImageForURL:[urlRequest URL] cacheName:cacheName];
    if (cachedImage) {
        self.image = cachedImage;
        self.af_imageRequestOperation = nil;
        
        if (success) {
            success(nil, nil, cachedImage);
        }
    } else {
        self.image = placeholderImage;
        
        AFImageRequestOperation *requestOperation = [[[AFImageRequestOperation alloc] initWithRequest:urlRequest] autorelease];
        [requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
            void(^successBlock)(id) = ^(id responseObject){
                if ([[urlRequest URL] isEqual:[[self.af_imageRequestOperation request] URL]]) {
                    self.image = responseObject;
                }
                
                if (success) {
                    success(operation.request, operation.response, responseObject);
                }
            };
            
            if (cacheName == nil) {
                successBlock(responseObject);
                [[[self class] af_sharedImageCache] cacheImageData:operation.responseData forURL:[urlRequest URL] cacheName:nil];
            } else {
                dispatch_queue_t calling_queue = dispatch_get_current_queue();
                dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    UIImage* image = resizeImageToFitSize(responseObject, size);
                    dispatch_async(calling_queue, ^{
                        successBlock(image);
                        [[[self class] af_sharedImageCache] cacheImageData:operation.responseData forURL:[urlRequest URL] cacheName:nil];
                        
                        NSData* imageData;
                        NSString* pathExtension = [[[[urlRequest URL] absoluteString] pathExtension] lowercaseString];
                        if ([pathExtension isEqualToString:@"jpg"] || [pathExtension isEqualToString:@"jpeg"])
                            imageData = UIImageJPEGRepresentation(image, 0.8);
                        else
                            imageData = UIImagePNGRepresentation(image);
                        [[[self class] af_sharedImageCache] cacheImageData:imageData forURL:[urlRequest URL] cacheName:cacheName];
                    });
                });
            }
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
            if (failure) {
                failure(operation.request, operation.response, error);
            }
        }];
        
        self.af_imageRequestOperation = requestOperation;
        
        [[[self class] af_sharedImageRequestOperationQueue] addOperation:self.af_imageRequestOperation];
    }
}

- (void)cancelImageRequestOperation {
    [self.af_imageRequestOperation cancel];
}

@end

#pragma mark -

static inline NSString * AFImageCacheKeyFromURLAndCacheName(NSURL *url, NSString *cacheName) {
    return [[url absoluteString] stringByAppendingFormat:@"#%@", cacheName];
}

@implementation AFImageCache
@synthesize imageScale = _imageScale;

- (id)init {
	self = [super init];
	if (!self) {
		return nil;
	}
    
    self.imageScale = [[UIScreen mainScreen] scale];
	
	return self;
}

- (UIImage *)cachedImageForURL:(NSURL *)url
                     cacheName:(NSString *)cacheName
{
	UIImage *image = [UIImage imageWithData:[self objectForKey:AFImageCacheKeyFromURLAndCacheName(url, cacheName)]];
	if (image) {
		return [UIImage imageWithCGImage:[image CGImage] scale:self.imageScale orientation:image.imageOrientation];
	}
    return image;
}

- (void)cacheImageData:(NSData *)imageData
                forURL:(NSURL *)url
             cacheName:(NSString *)cacheName
{
    [self setObject:[NSPurgeableData dataWithData:imageData] forKey:AFImageCacheKeyFromURLAndCacheName(url, cacheName)];
}

@end

#pragma mark -

static inline UIImage * resizeImageToFitSize(UIImage *image, CGSize fitSize)
{
	float imageScaleFactor = 1.0;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 40000
	if ([image respondsToSelector:@selector(scale)]) {
		imageScaleFactor = [image scale];
	}
#endif
    
    float sourceWidth = [image size].width * imageScaleFactor;
    float sourceHeight = [image size].height * imageScaleFactor;
    float targetWidth = fitSize.width;
    float targetHeight = fitSize.height;
    
    // Calculate aspect ratios
    float sourceRatio = sourceWidth / sourceHeight;
    float targetRatio = targetWidth / targetHeight;
    
    // Determine what side of the source image to use for proportional scaling
    BOOL scaleWidth = !(sourceRatio <= targetRatio);
    
    // Proportionally scale source image
    float scalingFactor, scaledWidth, scaledHeight;
    if (scaleWidth) {
        scalingFactor = 1.0 / sourceRatio;
        scaledWidth = targetWidth;
        scaledHeight = round(targetWidth * scalingFactor);
    } else {
        scalingFactor = sourceRatio;
        scaledWidth = round(targetHeight * scalingFactor);
        scaledHeight = targetHeight;
    }
    
    // Calculate compositing rectangles
    CGRect sourceRect = CGRectMake(0, 0, sourceWidth, sourceHeight);
    CGRect destRect = CGRectMake(0, 0, scaledWidth, scaledHeight);
    
    // Create appropriately modified image.
	UIImage *resizedImage = nil;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 40000
	if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 4.0) {
		UIGraphicsBeginImageContextWithOptions(destRect.size, NO, 0.0); // 0.0 for scale means "correct scale for device's main screen".
		CGImageRef sourceImg = CGImageCreateWithImageInRect([image CGImage], sourceRect); // cropping happens here.
		resizedImage = [UIImage imageWithCGImage:sourceImg scale:0.0 orientation:image.imageOrientation]; // create cropped UIImage.
		[resizedImage drawInRect:destRect]; // the actual scaling happens here, and orientation is taken care of automatically.
		CGImageRelease(sourceImg);
		resizedImage = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
	}
#endif
	if (!resizedImage) {
		// Try older method.
		CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
		CGContextRef context = CGBitmapContextCreate(NULL, fitSize.width, fitSize.height, 8, (fitSize.width * 4), 
													 colorSpace, kCGImageAlphaPremultipliedLast);
		CGImageRef sourceImg = CGImageCreateWithImageInRect([image CGImage], sourceRect);
		CGContextDrawImage(context, destRect, sourceImg);
		CGImageRelease(sourceImg);
		CGImageRef finalImage = CGBitmapContextCreateImage(context);	
		CGContextRelease(context);
		CGColorSpaceRelease(colorSpace);
		resizedImage = [UIImage imageWithCGImage:finalImage];
		CGImageRelease(finalImage);
	}
    
    return resizedImage;
}

#endif
