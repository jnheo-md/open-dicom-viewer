// DCMTKHelper.mm
// OpenDicomViewer
//
// Objective-C++ bridge to the DCMTK library. Provides two interfaces:
//
// 1. DCMTKHelper (class methods):
//    - convertDICOMToNSImage: Full DICOM-to-NSImage conversion
//    - getRawPixelData: Extract raw pixel buffer with metadata
//    - decodeJPEG2000DICOM: OpenJPEG fallback for JPEG 2000 transfer syntaxes
//    - lastErrorForPath: Human-readable error for failed loads
//
// 2. DCMTKImageObject (instance, retains decoded state):
//    - Keeps the decoded DCMTK image in memory for efficient re-rendering
//      at different window/level values without re-parsing the file
//    - Used for interactive W/L adjustment
//
// Supports standard DICOM transfer syntaxes including JPEG, JPEG-LS,
// and JPEG 2000 (via OpenJPEG). Handles both 8-bit and 16-bit pixel data,
// signed/unsigned, and Monochrome1/Monochrome2 photometric interpretations.

#import "DCMTKHelper.h"

// DCMTK Headers
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmdata/dctk.h"
#include "dcmtk/dcmdata/dcpixel.h"     // DcmPixelData
#include "dcmtk/dcmdata/dcpixseq.h"    // DcmPixelSequence
#include "dcmtk/dcmdata/dcpxitem.h"    // DcmPixelItem
#include "dcmtk/dcmdata/dcrledrg.h"    // RLE decoder registration
#include "dcmtk/dcmimgle/dcmimage.h"
#include "dcmtk/dcmjpeg/djdecode.h"    // JPEG decoder registration
#include "dcmtk/dcmjpls/djdecode.h"    // JPEG-LS decoder registration

// OpenJPEG for JPEG2000 fallback (no dcmjp2k in DCMTK 3.6.8)
#include "openjpeg.h"

// Shared initialization — must run before ANY DCMTK usage from either class
static void ensureDCMTKInitialized(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Set DCMDICTPATH to the bundled dicom.dic
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *dicPath = [mainBundle pathForResource:@"dicom" ofType:@"dic"];

    if (dicPath) {
      setenv("DCMDICTPATH", [dicPath UTF8String], 1);
    } else {
      NSLog(@"[DCMTKHelper] WARNING: dicom.dic not found in application bundle!");
    }

    // Register ALL available decoders globally
    DJDecoderRegistration::registerCodecs();      // JPEG (baseline, lossless)
    DJLSDecoderRegistration::registerCodecs();    // JPEG-LS (common in Korean equipment)
    DcmRLEDecoderRegistration::registerCodecs();  // RLE Lossless
    // Note: JPEG2000 handled via OpenJPEG fallback (no dcmjp2k in DCMTK 3.6.8)
  });
}

@implementation DCMTKHelper

+ (void)initialize {
  ensureDCMTKInitialized();
}

+ (NSImage *)convertDICOMToNSImage:(NSString *)path {
  if (!path)
    return nil;

  DicomImage *image = new DicomImage([path UTF8String]);
  if (image == NULL)
    return nil;
  if (image->getStatus() != EIS_Normal) {
    delete image;
    return nil;
  }

  unsigned long width = image->getWidth();
  unsigned long height = image->getHeight();
  int samples = image->isMonochrome() ? 1 : 3;

  // Force 8-bit output for display
  unsigned long size = image->getOutputDataSize(8);
  if (size == 0) {
    delete image;
    return nil;
  }

  uint8_t *buffer = (uint8_t *)malloc(size);
  if (image->getOutputData(buffer, size, 8)) {
    CGColorSpaceRef colorSpace = image->isMonochrome()
                                     ? CGColorSpaceCreateDeviceGray()
                                     : CGColorSpaceCreateDeviceRGB();

    // CFData takes ownership of buffer if we use kCFAllocatorMalloc?
    // No, CFDataCreateWithBytesNoCopy with kCFAllocatorMalloc means CFData will
    // call free() on release.
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buffer,
                                                 size, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);

    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault | kCGImageAlphaNone;

    CGImageRef cgImage = CGImageCreate(
        width, height, 8, 8 * samples, width * samples, colorSpace, bitmapInfo,
        provider, NULL, false, kCGRenderingIntentDefault);

    NSImage *nsImage =
        [[NSImage alloc] initWithCGImage:cgImage
                                    size:NSMakeSize(width, height)];

    CGImageRelease(cgImage);
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(colorSpace);

    delete image;
    return nsImage;
  }

  free(buffer);
  delete image;
  return nil;
}

+ (NSData *)getRawPixelData:(NSString *)path
                      width:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned {
  if (!path)
    return nil;

  // We use DicomImage to handle decompression and Modality LUT (Rescale)
  // CIF_DecompressCompletePixelData ensures compressed images (JPEG2000) are
  // fully decoded
  DicomImage *image =
      new DicomImage([path UTF8String], CIF_DecompressCompletePixelData);
  if (image == NULL)
    return nil;
  if (image->getStatus() != EIS_Normal) {
    delete image;
    return nil;
  }

  *width = image->getWidth();
  *height = image->getHeight();
  *samples = image->isMonochrome() ? 1 : 3;

  // Use getInterData() to get the pixel data AFTER Modality LUT but BEFORE VOI
  // LUT. This gives us the "Rescaled" values (e.g. Hounsfield Units) which is
  // what we want for W/L.
  const DiPixel *interData = image->getInterData();
  if (!interData) {
    delete image;
    return nil;
  }

  unsigned long count = interData->getCount();
  EP_Representation rep = interData->getRepresentation();

  size_t elementSize = 0;
  switch (rep) {
  case EPR_Uint8:
  case EPR_Sint8:
    elementSize = 1;
    *bitDepth = 8;
    break;
  case EPR_Uint16:
  case EPR_Sint16:
    elementSize = 2;
    *bitDepth = 16;
    break;
  case EPR_Uint32:
  case EPR_Sint32:
    elementSize = 4;
    *bitDepth = 32;
    break;
  default:
    delete image;
    return nil;
  }

  *isSigned = (rep == EPR_Sint8 || rep == EPR_Sint16 || rep == EPR_Sint32);

  unsigned long totalSize = count * elementSize;
  NSData *data = [NSData dataWithBytes:interData->getData() length:totalSize];

  delete image;
  return data;
}

+ (NSString *)lastErrorForPath:(NSString *)path {
  if (!path)
    return @"No path provided";

  DcmFileFormat fileformat;
  OFCondition status = fileformat.loadFile([path UTF8String]);
  if (status.bad()) {
    return [NSString
        stringWithFormat:@"Cannot read DICOM file: %s", status.text()];
  }

  // Try to create DicomImage to get its specific error
  DicomImage *image =
      new DicomImage([path UTF8String], CIF_DecompressCompletePixelData);
  if (image == NULL) {
    return @"Failed to allocate DicomImage";
  }

  EI_Status imgStatus = image->getStatus();
  NSString *errorStr = nil;
  if (imgStatus != EIS_Normal) {
    // Map common status codes to readable messages
    switch (imgStatus) {
    case EIS_NoDataDictionary:
      errorStr = @"DCMTK data dictionary not found (dicom.dic missing)";
      break;
    case EIS_InvalidDocument:
      errorStr = @"Invalid DICOM document";
      break;
    case EIS_MissingAttribute:
      errorStr = @"Missing required DICOM attribute";
      break;
    case EIS_InvalidValue:
      errorStr = @"Invalid DICOM attribute value";
      break;
    case EIS_InvalidImage:
      errorStr = @"Invalid image data";
      break;
    case EIS_NotSupportedValue:
      errorStr = @"Unsupported pixel value representation";
      break;
    default:
      errorStr =
          [NSString stringWithFormat:@"DicomImage error (status: %d)",
                                     (int)imgStatus];
      break;
    }
  }

  delete image;
  return errorStr;
}

// OpenJPEG callbacks for memory-based stream
struct MemoryStreamState {
  const uint8_t *data;
  OPJ_SIZE_T size;
  OPJ_SIZE_T offset;
};

static OPJ_SIZE_T opj_mem_read(void *p_buffer, OPJ_SIZE_T p_nb_bytes,
                                void *p_user_data) {
  MemoryStreamState *state = (MemoryStreamState *)p_user_data;
  OPJ_SIZE_T remaining = state->size - state->offset;
  if (remaining == 0)
    return (OPJ_SIZE_T)-1;
  OPJ_SIZE_T toRead = (p_nb_bytes < remaining) ? p_nb_bytes : remaining;
  memcpy(p_buffer, state->data + state->offset, toRead);
  state->offset += toRead;
  return toRead;
}

static OPJ_OFF_T opj_mem_skip(OPJ_OFF_T p_nb_bytes, void *p_user_data) {
  MemoryStreamState *state = (MemoryStreamState *)p_user_data;
  if (p_nb_bytes < 0) {
    // Backward skip
    if ((OPJ_SIZE_T)(-p_nb_bytes) > state->offset)
      state->offset = 0;
    else
      state->offset -= (OPJ_SIZE_T)(-p_nb_bytes);
  } else {
    OPJ_SIZE_T newOffset = state->offset + (OPJ_SIZE_T)p_nb_bytes;
    state->offset = (newOffset > state->size) ? state->size : newOffset;
  }
  return (OPJ_OFF_T)state->offset;
}

static OPJ_BOOL opj_mem_seek(OPJ_OFF_T p_nb_bytes, void *p_user_data) {
  MemoryStreamState *state = (MemoryStreamState *)p_user_data;
  if (p_nb_bytes < 0 || (OPJ_SIZE_T)p_nb_bytes > state->size)
    return OPJ_FALSE;
  state->offset = (OPJ_SIZE_T)p_nb_bytes;
  return OPJ_TRUE;
}

static void opj_error_callback(const char *msg, void *client_data) {
  NSLog(@"[OpenJPEG ERROR] %s", msg);
}
static void opj_warning_callback(const char *msg, void *client_data) {
  // Suppress warnings for cleaner logs
}
static void opj_info_callback(const char *msg, void *client_data) {
  // Suppress info for cleaner logs
}

+ (NSData *)decodeJPEG2000DICOM:(NSString *)path
                          width:(NSInteger *)width
                         height:(NSInteger *)height
                       bitDepth:(NSInteger *)bitDepth
                        samples:(NSInteger *)samples
                       isSigned:(BOOL *)isSigned {
  if (!path)
    return nil;

  // 1. Load DICOM dataset
  DcmFileFormat fileformat;
  OFCondition status = fileformat.loadFile([path UTF8String]);
  if (status.bad()) {
    NSLog(@"[J2K] Cannot load DICOM: %s", status.text());
    return nil;
  }

  DcmDataset *dataset = fileformat.getDataset();
  if (!dataset) {
    NSLog(@"[J2K] No dataset");
    return nil;
  }

  // 2. Check transfer syntax for JPEG2000
  OFString tsUID;
  fileformat.getMetaInfo()->findAndGetOFString(DCM_TransferSyntaxUID, tsUID);
  NSString *transferSyntax =
      [NSString stringWithUTF8String:tsUID.c_str()];

  BOOL isJPEG2000 =
      [transferSyntax isEqualToString:@"1.2.840.10008.1.2.4.90"] || // Lossless
      [transferSyntax isEqualToString:@"1.2.840.10008.1.2.4.91"];   // Lossy

  if (!isJPEG2000) {
    NSLog(@"[J2K] Not JPEG2000 transfer syntax: %@", transferSyntax);
    return nil;
  }

  // 3. Get image dimensions from DICOM tags
  Uint16 dcmRows = 0, dcmCols = 0, dcmBitsAlloc = 0, dcmBitsStored = 0;
  Uint16 dcmSamplesPerPixel = 0, dcmPixelRep = 0;
  dataset->findAndGetUint16(DCM_Rows, dcmRows);
  dataset->findAndGetUint16(DCM_Columns, dcmCols);
  dataset->findAndGetUint16(DCM_BitsAllocated, dcmBitsAlloc);
  dataset->findAndGetUint16(DCM_BitsStored, dcmBitsStored);
  dataset->findAndGetUint16(DCM_SamplesPerPixel, dcmSamplesPerPixel);
  dataset->findAndGetUint16(DCM_PixelRepresentation, dcmPixelRep);

  if (dcmRows == 0 || dcmCols == 0) {
    NSLog(@"[J2K] Invalid dimensions: %dx%d", dcmCols, dcmRows);
    return nil;
  }

  // 4. Extract encapsulated pixel data
  DcmElement *pixelElement = NULL;
  status = dataset->findAndGetElement(DCM_PixelData, pixelElement);
  if (status.bad() || !pixelElement) {
    NSLog(@"[J2K] No pixel data element");
    return nil;
  }

  DcmPixelData *pixelData = OFstatic_cast(DcmPixelData *, pixelElement);
  DcmPixelSequence *pixelSeq = NULL;
  E_TransferSyntax xfer = dataset->getOriginalXfer();
  status = pixelData->getEncapsulatedRepresentation(xfer, NULL, pixelSeq);
  if (status.bad() || !pixelSeq) {
    NSLog(@"[J2K] Cannot get encapsulated representation");
    return nil;
  }

  // Skip offset table (first item), get first actual frame
  DcmPixelItem *pixelItem = NULL;
  // Item 0 is the offset table, item 1+ are actual frames
  Uint32 numItems = pixelSeq->card();
  if (numItems < 2) {
    NSLog(@"[J2K] No frame data items (only %d items)", numItems);
    return nil;
  }

  // Collect all frame fragments (may be split across multiple items)
  NSMutableData *j2kData = [NSMutableData data];
  for (Uint32 i = 1; i < numItems; i++) {
    status = pixelSeq->getItem(pixelItem, i);
    if (status.bad() || !pixelItem)
      break;
    Uint8 *fragData = NULL;
    status = pixelItem->getUint8Array(fragData);
    if (status.good() && fragData) {
      [j2kData appendBytes:fragData length:pixelItem->getLength()];
    }
  }

  if (j2kData.length == 0) {
    NSLog(@"[J2K] No compressed data extracted");
    return nil;
  }

  // 5. Decode with OpenJPEG
  opj_dparameters_t parameters;
  opj_set_default_decoder_parameters(&parameters);

  // Detect codec type from stream header
  opj_codec_t *codec = NULL;
  const uint8_t *j2kBytes = (const uint8_t *)j2kData.bytes;

  // JP2 format starts with 0x0000000C (box header)
  // J2K codestream starts with 0xFF4F (SOC marker)
  if (j2kData.length >= 4 && j2kBytes[0] == 0xFF && j2kBytes[1] == 0x4F) {
    codec = opj_create_decompress(OPJ_CODEC_J2K);
  } else {
    codec = opj_create_decompress(OPJ_CODEC_JP2);
  }

  if (!codec) {
    NSLog(@"[J2K] Failed to create OpenJPEG decoder");
    return nil;
  }

  opj_set_error_handler(codec, opj_error_callback, NULL);
  opj_set_warning_handler(codec, opj_warning_callback, NULL);
  opj_set_info_handler(codec, opj_info_callback, NULL);

  if (!opj_setup_decoder(codec, &parameters)) {
    NSLog(@"[J2K] Failed to setup decoder");
    opj_destroy_codec(codec);
    return nil;
  }

  // Create memory-based stream using custom callbacks
  MemoryStreamState *streamState = new MemoryStreamState();
  streamState->data = (const uint8_t *)j2kData.bytes;
  streamState->size = j2kData.length;
  streamState->offset = 0;

  opj_stream_t *stream = opj_stream_create(OPJ_J2K_STREAM_CHUNK_SIZE, OPJ_TRUE);
  if (!stream) {
    NSLog(@"[J2K] Failed to create stream");
    delete streamState;
    opj_destroy_codec(codec);
    return nil;
  }

  opj_stream_set_user_data(stream, streamState, NULL);
  opj_stream_set_user_data_length(stream, j2kData.length);
  opj_stream_set_read_function(stream, opj_mem_read);
  opj_stream_set_skip_function(stream, opj_mem_skip);
  opj_stream_set_seek_function(stream, opj_mem_seek);

  opj_image_t *image = NULL;
  if (!opj_read_header(stream, codec, &image)) {
    NSLog(@"[J2K] Failed to read JPEG2000 header");
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    delete streamState;
    return nil;
  }

  if (!opj_decode(codec, stream, image)) {
    NSLog(@"[J2K] Failed to decode JPEG2000 data");
    opj_image_destroy(image);
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    delete streamState;
    return nil;
  }

  opj_stream_destroy(stream);
  opj_destroy_codec(codec);
  delete streamState;

  // 6. Convert OpenJPEG image to raw pixel data
  if (!image || image->numcomps == 0) {
    NSLog(@"[J2K] Decoded image has no components");
    if (image)
      opj_image_destroy(image);
    return nil;
  }

  OPJ_UINT32 imgWidth = image->comps[0].w;
  OPJ_UINT32 imgHeight = image->comps[0].h;
  OPJ_UINT32 numComps = image->numcomps;
  OPJ_UINT32 prec = image->comps[0].prec;
  BOOL sgnd = image->comps[0].sgnd;

  *width = imgWidth;
  *height = imgHeight;
  *samples = numComps;
  *isSigned = sgnd || (dcmPixelRep == 1);

  NSData *result = nil;

  if (prec <= 8) {
    *bitDepth = 8;
    size_t totalSize = imgWidth * imgHeight * numComps;
    uint8_t *outBuffer = (uint8_t *)malloc(totalSize);

    if (numComps == 1) {
      OPJ_INT32 *src = image->comps[0].data;
      for (OPJ_UINT32 i = 0; i < imgWidth * imgHeight; i++) {
        outBuffer[i] = (uint8_t)OFstatic_cast(int, src[i]);
      }
    } else {
      for (OPJ_UINT32 i = 0; i < imgWidth * imgHeight; i++) {
        for (OPJ_UINT32 c = 0; c < numComps; c++) {
          outBuffer[i * numComps + c] =
              (uint8_t)OFstatic_cast(int, image->comps[c].data[i]);
        }
      }
    }

    result = [NSData dataWithBytesNoCopy:outBuffer
                                  length:totalSize
                            freeWhenDone:YES];
  } else {
    *bitDepth = 16;
    size_t totalSize = imgWidth * imgHeight * numComps * 2;
    uint16_t *outBuffer = (uint16_t *)malloc(totalSize);

    if (numComps == 1) {
      OPJ_INT32 *src = image->comps[0].data;
      for (OPJ_UINT32 i = 0; i < imgWidth * imgHeight; i++) {
        if (*isSigned) {
          ((int16_t *)outBuffer)[i] = (int16_t)src[i];
        } else {
          outBuffer[i] = (uint16_t)src[i];
        }
      }
    } else {
      for (OPJ_UINT32 i = 0; i < imgWidth * imgHeight; i++) {
        for (OPJ_UINT32 c = 0; c < numComps; c++) {
          OPJ_UINT32 idx = i * numComps + c;
          if (*isSigned) {
            ((int16_t *)outBuffer)[idx] =
                (int16_t)image->comps[c].data[i];
          } else {
            outBuffer[idx] = (uint16_t)image->comps[c].data[i];
          }
        }
      }
    }

    result = [NSData dataWithBytesNoCopy:outBuffer
                                  length:totalSize
                            freeWhenDone:YES];
  }

  opj_image_destroy(image);

  NSLog(@"[J2K] Successfully decoded %ldx%ld %ldbit %ldch",
        (long)*width, (long)*height, (long)*bitDepth, (long)*samples);
  return result;
}

@end

@implementation DCMTKImageObject {
  DicomImage *_image;
}

+ (void)initialize {
  ensureDCMTKInitialized();
}

- (instancetype)initWithPath:(NSString *)path {
  self = [super init];
  if (self) {
    _image = new DicomImage([path UTF8String], CIF_DecompressCompletePixelData);
    if (_image == NULL || _image->getStatus() != EIS_Normal) {
      if (_image)
        delete _image;
      _image = NULL;
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  if (_image) {
    delete _image;
    _image = NULL;
  }
}

- (NSImage *)renderImageWithWidth:(NSInteger)width
                           height:(NSInteger)height
                               ww:(double)ww
                               wc:(double)wc {
  if (!_image)
    return nil;

  // Set Window/Level
  // Note: DicomImage::setWindow takes center, width
  if (ww > 0) {
    _image->setWindow(wc, ww);
  }

  // Output 8-bit for display
  unsigned long size = _image->getOutputDataSize(8);
  if (size == 0)
    return nil;

  uint8_t *buffer = (uint8_t *)malloc(size);
  if (_image->getOutputData(buffer, size, 8)) {
    CGColorSpaceRef colorSpace = _image->isMonochrome()
                                     ? CGColorSpaceCreateDeviceGray()
                                     : CGColorSpaceCreateDeviceRGB();

    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buffer,
                                                 size, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);

    int samples = _image->isMonochrome() ? 1 : 3;
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault | kCGImageAlphaNone;

    CGImageRef cgImage =
        CGImageCreate(_image->getWidth(), _image->getHeight(), 8, 8 * samples,
                      _image->getWidth() * samples, colorSpace, bitmapInfo,
                      provider, NULL, false, kCGRenderingIntentDefault);

    // Use actual image dimensions when caller passes 0
    NSInteger finalWidth = (width > 0) ? width : (NSInteger)_image->getWidth();
    NSInteger finalHeight = (height > 0) ? height : (NSInteger)_image->getHeight();

    NSImage *nsImage =
        [[NSImage alloc] initWithCGImage:cgImage
                                    size:NSMakeSize(finalWidth, finalHeight)];

    CGImageRelease(cgImage);
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(colorSpace);

    return nsImage;
  }

  free(buffer);
  return nil;
}

- (NSData *)getRawDataWidth:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned {
  if (!_image)
    return nil;

  *width = _image->getWidth();
  *height = _image->getHeight();
  *samples = _image->isMonochrome() ? 1 : 3;

  // Use getInterData() for raw values (after Modality LUT)
  const DiPixel *interData = _image->getInterData();
  if (!interData)
    return nil;

  unsigned long count = interData->getCount();
  EP_Representation rep = interData->getRepresentation();

  size_t elementSize = 0;
  switch (rep) {
  case EPR_Uint8:
  case EPR_Sint8:
    elementSize = 1;
    *bitDepth = 8;
    break;
  case EPR_Uint16:
  case EPR_Sint16:
    elementSize = 2;
    *bitDepth = 16;
    break;
  case EPR_Uint32:
  case EPR_Sint32:
    elementSize = 4;
    *bitDepth = 32;
    break;
  default:
    return nil;
  }

  *isSigned = (rep == EPR_Sint8 || rep == EPR_Sint16 || rep == EPR_Sint32);

  unsigned long totalSize = count * elementSize;
  return [NSData dataWithBytes:interData->getData() length:totalSize];
}

- (double)getWindowWidth {
  if (!_image)
    return 0;
  double c, w;
  if (_image->getWindow(c, w)) {
    return w;
  }
  return 0;
}

- (double)getWindowCenter {
  if (!_image)
    return 0;
  double c, w;
  if (_image->getWindow(c, w)) {
    return c;
  }
  return 0;
}

@end
