#include <android/api-level.h>
#include <android/imagedecoder.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

// A page held open. The file descriptor is kept because a decoder is built
// fresh for every decode: AImageDecoder_rewind is API 31 and documented around
// animated images, so reusing a decoder for a second still-image decode is not
// something API 30 promises.
typedef struct {
  int fd;
  int32_t width;
  int32_t height;
} TileHandle;

int32_t tile_available(void) {
  return android_get_device_api_level() >= 30 ? 1 : 0;
}

void* tile_open(const char* path, int32_t* out_w, int32_t* out_h) {
  if (!tile_available() || path == NULL) return NULL;

  int fd = open(path, O_RDONLY);
  if (fd < 0) return NULL;

  AImageDecoder* dec = NULL;
  if (AImageDecoder_createFromFd(fd, &dec) != ANDROID_IMAGE_DECODER_SUCCESS) {
    close(fd);
    return NULL;
  }

  const AImageDecoderHeaderInfo* info = AImageDecoder_getHeaderInfo(dec);
  int32_t w = AImageDecoderHeaderInfo_getWidth(info);
  int32_t h = AImageDecoderHeaderInfo_getHeight(info);
  AImageDecoder_delete(dec);

  if (w <= 0 || h <= 0) {
    close(fd);
    return NULL;
  }

  TileHandle* handle = (TileHandle*)malloc(sizeof(TileHandle));
  if (handle == NULL) {
    close(fd);
    return NULL;
  }
  handle->fd = fd;
  handle->width = w;
  handle->height = h;
  *out_w = w;
  *out_h = h;
  return handle;
}

bool tile_decode(void* h, int32_t x, int32_t y, int32_t w, int32_t h_,
                 int32_t sample, uint8_t* out, int32_t out_len,
                 int32_t* out_stride) {
  if (h == NULL || out == NULL || sample < 1) return false;
  TileHandle* handle = (TileHandle*)h;

  if (lseek(handle->fd, 0, SEEK_SET) < 0) return false;

  AImageDecoder* dec = NULL;
  if (AImageDecoder_createFromFd(handle->fd, &dec) !=
      ANDROID_IMAGE_DECODER_SUCCESS) {
    return false;
  }

  bool ok = false;
  do {
    // Order matters: the crop is applied to the SCALED image, so the target
    // size is set first and the crop is expressed in scaled coordinates.
    int32_t sw = handle->width / sample;
    int32_t sh = handle->height / sample;
    if (sw < 1) sw = 1;
    if (sh < 1) sh = 1;
    if (AImageDecoder_setTargetSize(dec, sw, sh) !=
        ANDROID_IMAGE_DECODER_SUCCESS) {
      break;
    }

    ARect crop;
    crop.left = x;
    crop.top = y;
    crop.right = x + w;
    crop.bottom = y + h_;

    // Clamp to the scaled image instead of refusing. The caller divides the
    // page by the same sample but rounds, while sw/sh truncate, so a page
    // whose size is not an exact multiple of the sample asks for one pixel
    // more than exists: a 1080-wide page at sample 16 is 67.5, requested as
    // 68, and 67 is what there is. Refusing that failed EVERY tile of every
    // such page and fell back silently, which measured as "tiling saves
    // nothing" rather than as a bug.
    if (crop.right > sw) crop.right = sw;
    if (crop.bottom > sh) crop.bottom = sh;

    if (crop.left < 0 || crop.top < 0 || crop.left >= sw || crop.top >= sh ||
        crop.right <= crop.left || crop.bottom <= crop.top) {
      break;
    }
    if (AImageDecoder_setCrop(dec, crop) != ANDROID_IMAGE_DECODER_SUCCESS) {
      break;
    }

    if (AImageDecoder_setAndroidBitmapFormat(
            dec, ANDROID_BITMAP_FORMAT_RGBA_8888) !=
        ANDROID_IMAGE_DECODER_SUCCESS) {
      break;
    }

    size_t stride = AImageDecoder_getMinimumStride(dec);
    int32_t rows = crop.bottom - crop.top;
    if ((int64_t)stride * rows > (int64_t)out_len) break;

    if (AImageDecoder_decodeImage(dec, out, stride, stride * rows) !=
        ANDROID_IMAGE_DECODER_SUCCESS) {
      break;
    }
    *out_stride = (int32_t)stride;
    ok = true;
  } while (0);

  AImageDecoder_delete(dec);
  return ok;
}

void tile_close(void* h) {
  if (h == NULL) return;
  TileHandle* handle = (TileHandle*)h;
  close(handle->fd);
  free(handle);
}
