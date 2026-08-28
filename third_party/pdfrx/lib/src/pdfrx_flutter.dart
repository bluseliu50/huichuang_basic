import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show WidgetsFlutterBinding;
import 'package:flutter/services.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'utils/platform.dart';

bool _isInitialized = false;

/// Explicitly initializes the Pdfrx library for Flutter.
///
/// This function actually sets up the following functions:
/// - [Pdfrx.loadAsset]: Loads an asset by name and returns its byte data.
/// - [Pdfrx.cacheDirectoryPath]: The path to the temporary directory for caching (For Web, it is not applicable).
/// - Call [PdfrxEntryFunctions.init] to initialize the library.
///
/// For Dart (non-Flutter) programs, you should call [pdfrxInitialize] instead.
Future<void> pdfrxFlutterInitialize({
  @Deprecated('WASM modules are now only included in web builds. This flag now does nothing.')
  bool dismissPdfiumWasmWarnings = false,
}) async {
  if (_isInitialized) return;

  WidgetsFlutterBinding.ensureInitialized();

  if (pdfrxEntryFunctionsOverride != null) {
    PdfrxEntryFunctions.instance = pdfrxEntryFunctionsOverride!;
  }

  Pdfrx.loadAsset ??= (name) async {
    final asset = await rootBundle.load(name);
    return asset.buffer.asUint8List();
  };

  if (!kIsWeb) {
    Pdfrx.cacheDirectoryPath ??= await getCacheDirectory();
  }

  /// NOTE: it's actually async, but hopefully, it finishes quickly...
  await platformInitialize();

  _isInitialized = true;
}

extension PdfPageExt on PdfPage {
  /// PDF page size in points (size in pixels at 72 dpi) (rotated).
  Size get size => Size(width, height);
}

extension PdfImageExt on PdfImage {
  /// Create [Image] from the rendered image.
  ///
  /// [pixelSizeThreshold] specifies the maximum allowed pixel size (width or height).
  /// If the image exceeds this size, it will be downscaled to fit within the threshold
  /// while maintaining the aspect ratio.
  ///
  /// The returned [Image] must be disposed of when no longer needed.
  ///
  /// Throws if the engine cannot decode the pixel buffer, which in practice
  /// means it failed to allocate for it - a large page on a memory-constrained
  /// device. The returned future never completes with null.
  Future<Image> createImage({int? pixelSizeThreshold}) async {
    int? targetWidth;
    int? targetHeight;
    if (pixelSizeThreshold != null && (width > pixelSizeThreshold || height > pixelSizeThreshold)) {
      final aspectRatio = width / height;
      if (width >= height) {
        targetWidth = pixelSizeThreshold;
        targetHeight = (pixelSizeThreshold / aspectRatio).round();
      } else {
        targetHeight = pixelSizeThreshold;
        targetWidth = (pixelSizeThreshold * aspectRatio).round();
      }
    }

    // HC VENDOR PATCH (third_party/pdfrx): swap BGRA→RGBA and upload as
    // PixelFormat.rgba8888 instead of upstream's PixelFormat.bgra8888.
    // On the affected device (Pixel 9 Pro Fold, Tensor G3 / Mali-G715,
    // Android 16) raw uploads tagged bgra8888 composite to a BLANK image,
    // while the exact same pixels uploaded as rgba8888 display correctly
    // (verified with an on-device RawImage probe of page-1 pixels).
    // The swap is one linear pass; pages are opaque so alpha is forced
    // to 255. Falls back to the upstream path on any failure.
    try {
      final rgba = Uint8List(pixels.length);
      for (var i = 0; i < pixels.length; i += 4) {
        rgba[i] = pixels[i + 2];
        rgba[i + 1] = pixels[i + 1];
        rgba[i + 2] = pixels[i];
        rgba[i + 3] = 255;
      }
      final buffer = await ImmutableBuffer.fromUint8List(rgba);
      final descriptor = ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } on Exception {
      // fall through to the upstream path below
    }

    // Upstream 2.4.8 path (bgra8888 raw upload), kept as fallback.
    final buffer = await ImmutableBuffer.fromUint8List(pixels);
    ImageDescriptor? descriptor;
    try {
      descriptor = ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: PixelFormat.bgra8888);
      final codec = await descriptor.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

extension ImageExt on Image {
  /// Convert [Image] to [PdfImage].
  Future<PdfImage> toPdfImage() async {
    final rgba = (await toByteData(format: ImageByteFormat.rawRgba))!.buffer.asUint8List();
    for (var i = 0; i < rgba.length; i += 4) {
      final r = rgba[i];
      rgba[i] = rgba[i + 2];
      rgba[i + 2] = r;
    }
    return PdfImage.createFromBgraData(rgba, width: width, height: height);
  }
}

extension PdfRectExt on PdfRect {
  /// Convert to [Rect] in Flutter coordinate.
  /// [page] is the page to convert the rectangle.
  /// [scaledPageSize] is the scaled page size to scale the rectangle. If not specified, [PdfPage].size is used.
  /// [rotation] is the rotation of the page. If not specified, [PdfPage.rotation] is used.
  Rect toRect({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final rotated = rotate(rotation ?? page.rotation.index, page);
    final scale = scaledPageSize == null ? 1.0 : scaledPageSize.height / page.height;
    return Rect.fromLTRB(
      rotated.left * scale,
      (page.height - rotated.top) * scale,
      rotated.right * scale,
      (page.height - rotated.bottom) * scale,
    );
  }

  ///  Convert to [Rect] in Flutter coordinate using [pageRect] as the page's bounding rectangle.
  Rect toRectInDocument({required PdfPage page, required Rect pageRect}) =>
      toRect(page: page, scaledPageSize: pageRect.size).translate(pageRect.left, pageRect.top);
}

extension RectPdfRectExt on Rect {
  /// Convert to [PdfRect] in PDF page coordinates.
  PdfRect toPdfRect({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final scale = scaledPageSize == null ? 1.0 : scaledPageSize.height / page.height;
    return PdfRect(
      left / scale,
      page.height - top / scale,
      right / scale,
      page.height - bottom / scale,
    ).rotateReverse(rotation ?? page.rotation.index, page);
  }
}

extension PdfPointExt on PdfPoint {
  /// Convert to [Offset] in Flutter coordinate.
  /// [page] is the page to convert the rectangle.
  /// [scaledPageSize] is the scaled page size to scale the rectangle. If not specified, [PdfPage].size is used.
  /// [rotation] is the rotation of the page. If not specified, [PdfPage.rotation] is used.
  Offset toOffset({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final rotated = rotate(rotation ?? page.rotation.index, page);
    final scale = scaledPageSize == null ? 1.0 : scaledPageSize.height / page.height;
    return Offset(rotated.x * scale, (page.height - rotated.y) * scale);
  }

  Offset toOffsetInDocument({required PdfPage page, required Rect pageRect}) {
    final rotated = rotate(page.rotation.index, page);
    final scale = pageRect.height / page.height;
    return Offset(rotated.x * scale, (page.height - rotated.y) * scale).translate(pageRect.left, pageRect.top);
  }
}

extension OffsetPdfPointExt on Offset {
  /// Convert to [PdfPoint] in PDF page coordinates.
  PdfPoint toPdfPoint({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final scale = scaledPageSize == null ? 1.0 : page.height / scaledPageSize.height;
    return PdfPoint(dx * scale, page.height - dy * scale).rotateReverse(rotation ?? page.rotation.index, page);
  }
}
