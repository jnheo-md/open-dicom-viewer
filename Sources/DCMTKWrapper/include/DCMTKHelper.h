// DCMTKHelper.h
// OpenDicomViewer
//
// Public Objective-C interface for the DCMTK wrapper. Exposes DICOM image
// decoding functionality to Swift via two classes:
//   - DCMTKHelper: Stateless class methods for one-shot decoding
//   - DCMTKImageObject: Retains decoded image state for efficient re-rendering

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface DCMTKHelper : NSObject

+ (NSImage *)convertDICOMToNSImage:(NSString *)path;
+ (NSData *)getRawPixelData:(NSString *)path
                      width:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned;

/// Returns a human-readable error string for the last failed DICOM load, or nil if no error.
+ (NSString *)lastErrorForPath:(NSString *)path;

/// Attempts to decode a JPEG2000-compressed DICOM file using OpenJPEG.
/// Returns raw decompressed pixel data, or nil on failure.
+ (NSData *)decodeJPEG2000DICOM:(NSString *)path
                          width:(NSInteger *)width
                         height:(NSInteger *)height
                       bitDepth:(NSInteger *)bitDepth
                        samples:(NSInteger *)samples
                       isSigned:(BOOL *)isSigned;

@end

@interface DCMTKImageObject : NSObject

- (instancetype)initWithPath:(NSString *)path;
- (NSImage *)renderImageWithWidth:(NSInteger)width
                           height:(NSInteger)height
                               ww:(double)ww
                               wc:(double)wc;
- (NSData *)getRawDataWidth:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned;
- (double)getWindowWidth;
- (double)getWindowCenter;

@end
