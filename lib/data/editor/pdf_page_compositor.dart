import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:pdfrx/pdfrx.dart';

/// One page of the PDF built by [PdfPageCompositor.compose].
class PdfCompositePage {
  const PdfCompositePage({
    required this.width,
    required this.height,
    this.source,
    this.sourcePage = 0,
    this.hasOverlay = true,
  });

  /// Size of the matching overlay page, in PDF points.
  final double width;
  final double height;

  /// Index into the `sources` list of the PDF whose page is the
  /// background of this page, or null for a page without one.
  final int? source;

  /// 0-based page index in that source PDF.
  final int sourcePage;

  /// Whether the overlay page has anything on it. Empty overlays
  /// are skipped so the original page is left untouched.
  final bool hasOverlay;
}

class PdfCompositorException implements Exception {
  const PdfCompositorException(this.message);

  final String message;

  @override
  String toString() => 'PdfCompositorException: $message';
}

/// A 2D affine transform in PDF form: `x' = a*x + c*y + e`,
/// `y' = b*x + d*y + f`.
@immutable
class PdfAffine {
  const PdfAffine(this.a, this.b, this.c, this.d, this.e, this.f);

  const PdfAffine.scale(double s) : this(s, 0, 0, s, 0, 0);

  final double a, b, c, d, e, f;

  (double, double) apply(double x, double y) =>
      (a * x + c * y + e, b * x + d * y + f);

  PdfAffine inverse() {
    final det = a * d - b * c;
    if (det == 0) throw const PdfCompositorException('Singular transform');
    return PdfAffine(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * f - d * e) / det,
      (b * e - a * f) / det,
    );
  }

  @override
  String toString() => 'PdfAffine($a, $b, $c, $d, $e, $f)';
}

/// Builds a PDF that keeps the original pages of imported PDFs
/// (text, fonts and vector graphics untouched) and draws an overlay
/// PDF page on top of each one.
///
/// All PDFium work runs synchronously on pdfrx's PDFium worker isolate,
/// so it can't race with pdfrx rendering PDFs on screen.
abstract final class PdfPageCompositor {
  /// The largest difference in aspect ratio between an overlay page and
  /// its source page that is still treated as a match.
  static const aspectRatioTolerance = 0.01;

  /// Composes the final PDF.
  ///
  /// [overlay] must have exactly one page per entry in [pages], in order.
  /// Throws if anything about the inputs or PDFium fails, so callers can
  /// fall back to another export method.
  static Future<Uint8List> compose({
    required Uint8List overlay,
    required List<Uint8List> sources,
    required List<PdfCompositePage> pages,
  }) async {
    if (pages.isEmpty) {
      throw const PdfCompositorException('No pages to compose');
    }
    await PdfrxEntryFunctions.instance.init();
    return PdfrxEntryFunctions.instance.compute(
      _composeInWorker,
      _ComposeRequest(overlay: overlay, sources: sources, pages: pages),
    );
  }

  /// The transform from a source page's own coordinates to overlay
  /// coordinates (origin bottom-left, size [overlayWidth] x
  /// [overlayHeight]), matching how Saber shows the page: rotated by
  /// [rotation] quarter turns clockwise, then scaled to fit and centered.
  ///
  /// [left], [bottom], [right], [top] describe the source page's visible
  /// box (crop box clipped to media box) in its own coordinates.
  @visibleForTesting
  static PdfAffine sourceToOverlay({
    required double left,
    required double bottom,
    required double right,
    required double top,
    required int rotation,
    required double overlayWidth,
    required double overlayHeight,
  }) {
    final boxWidth = right - left;
    final boxHeight = top - bottom;
    if (boxWidth <= 0 || boxHeight <= 0) {
      throw const PdfCompositorException('Empty page box');
    }
    final quarterTurns = rotation % 4;
    final rotated = quarterTurns.isOdd;
    final shownWidth = rotated ? boxHeight : boxWidth;
    final shownHeight = rotated ? boxWidth : boxHeight;

    final s = min(overlayWidth / shownWidth, overlayHeight / shownHeight);
    final ox = (overlayWidth - shownWidth * s) / 2;
    final oy = (overlayHeight - shownHeight * s) / 2;

    return switch (quarterTurns) {
      // X = x - left, Y = y - bottom
      0 => PdfAffine(s, 0, 0, s, ox - s * left, oy - s * bottom),
      // X = y - bottom, Y = right - x
      1 => PdfAffine(0, -s, s, 0, ox - s * bottom, oy + s * right),
      // X = right - x, Y = top - y
      2 => PdfAffine(-s, 0, 0, -s, ox + s * right, oy + s * top),
      // X = top - y, Y = x - left
      _ => PdfAffine(0, s, -s, 0, ox + s * top, oy - s * left),
    };
  }
}

class _ComposeRequest {
  const _ComposeRequest({
    required this.overlay,
    required this.sources,
    required this.pages,
  });

  final Uint8List overlay;
  final List<Uint8List> sources;
  final List<PdfCompositePage> pages;
}

class _PageGeometry {
  const _PageGeometry(this.left, this.bottom, this.right, this.top, this.rotation);

  final double left, bottom, right, top;
  final int rotation;

  double get shownWidth => rotation.isOdd ? top - bottom : right - left;
  double get shownHeight => rotation.isOdd ? right - left : top - bottom;
}

/// Runs on pdfrx's PDFium worker isolate. Must stay synchronous so the
/// whole job runs while pdfrx holds PDFium for us.
Uint8List _composeInWorker(_ComposeRequest request) {
  final pdfium = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  final pages = request.pages;
  final arena = Arena();
  final buffers = <Pointer<Uint8>>[];
  final openDocs = <FPDF_DOCUMENT>[];
  FPDF_DOCUMENT out = nullptr;

  Never fail(String message) => throw PdfCompositorException(message);

  FPDF_DOCUMENT load(Uint8List bytes, String name) {
    if (bytes.isEmpty) fail('$name is empty');
    final buffer = malloc<Uint8>(bytes.length);
    buffers.add(buffer);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final doc = pdfium.FPDF_LoadMemDocument64(
      buffer.cast(),
      bytes.length,
      nullptr,
    );
    if (doc == nullptr) {
      fail('Could not open $name (PDFium error ${pdfium.FPDF_GetLastError()})');
    }
    openDocs.add(doc);
    return doc;
  }

  T withPage<T>(int index, T Function(FPDF_PAGE page) action) {
    final page = pdfium.FPDF_LoadPage(out, index);
    if (page == nullptr) fail('Could not load output page $index');
    try {
      return action(page);
    } finally {
      pdfium.FPDF_ClosePage(page);
    }
  }

  _PageGeometry geometryOf(FPDF_PAGE page) {
    final rect = arena<FS_RECTF>();
    if (pdfium.FPDF_GetPageBoundingBox(page, rect) == 0) {
      fail('Could not read page box');
    }
    final rotation = pdfium.FPDFPage_GetRotation(page);
    if (rotation < 0) fail('Could not read page rotation');
    return _PageGeometry(
      min(rect.ref.left, rect.ref.right),
      min(rect.ref.bottom, rect.ref.top),
      max(rect.ref.left, rect.ref.right),
      max(rect.ref.bottom, rect.ref.top),
      rotation,
    );
  }

  void insertOverlay(
    FPDF_DOCUMENT overlay,
    FPDF_PAGE page,
    int overlayIndex,
    PdfAffine transform,
  ) {
    final xobject = pdfium.FPDF_NewXObjectFromPage(out, overlay, overlayIndex);
    if (xobject == nullptr) fail('Could not copy overlay page $overlayIndex');
    try {
      final form = pdfium.FPDF_NewFormObjectFromXObject(xobject);
      if (form == nullptr) fail('Could not create overlay form object');
      pdfium.FPDFPageObj_Transform(
        form,
        transform.a,
        transform.b,
        transform.c,
        transform.d,
        transform.e,
        transform.f,
      );
      if (pdfium.FPDFPage_InsertObject(page, form) == 0) {
        pdfium.FPDFPageObj_Destroy(form);
        fail('Could not insert overlay on page $overlayIndex');
      }
    } finally {
      pdfium.FPDF_CloseXObject(xobject);
    }
  }

  try {
    final overlay = load(request.overlay, 'overlay PDF');
    final sources = [
      for (var i = 0; i < request.sources.length; i++)
        load(request.sources[i], 'source PDF $i'),
    ];

    for (var i = 0; i < sources.length; i++) {
      // Encrypted PDFs may not copy cleanly into an unencrypted file.
      if (pdfium.FPDF_GetSecurityHandlerRevision(sources[i]) != -1) {
        fail('Source PDF $i is encrypted');
      }
    }
    if (pdfium.FPDF_GetPageCount(overlay) != pages.length) {
      fail('Overlay has ${pdfium.FPDF_GetPageCount(overlay)} pages, '
          'expected ${pages.length}');
    }
    for (var i = 0; i < pages.length; i++) {
      final source = pages[i].source;
      if (source == null) continue;
      if (source < 0 || source >= sources.length) {
        fail('Page $i refers to missing source $source');
      }
      final count = pdfium.FPDF_GetPageCount(sources[source]);
      if (pages[i].sourcePage < 0 || pages[i].sourcePage >= count) {
        fail('Page $i refers to page ${pages[i].sourcePage} '
            'of a $count-page PDF');
      }
    }

    out = pdfium.FPDF_CreateNewDocument();
    if (out == nullptr) fail('Could not create output PDF');

    // Where each page currently sits in [out]. Pages are created out of
    // order and moved into place at the end.
    final positions = List.filled(pages.length, -1);
    var pageCount = 0;

    // 1. Import every page of each source PDF in a single call, so fonts
    //    and images shared between pages are only stored once.
    for (var s = 0; s < sources.length; s++) {
      final members = [
        for (var i = 0; i < pages.length; i++)
          if (pages[i].source == s) i,
      ];
      if (members.isEmpty) continue;
      final indices = arena<Int>(members.length);
      for (var k = 0; k < members.length; k++) {
        indices[k] = pages[members[k]].sourcePage;
      }
      if (pdfium.FPDF_ImportPagesByIndex(
            out,
            sources[s],
            indices,
            members.length,
            pageCount,
          ) ==
          0) {
        fail('Could not import pages from source PDF $s');
      }
      for (var k = 0; k < members.length; k++) {
        positions[members[k]] = pageCount + k;
      }
      pageCount += members.length;
    }

    // 2. Pages without a PDF background are drawn from the overlay alone,
    //    scaled to the width of the PDF pages so the file has
    //    consistent page sizes.
    final firstPdfPage = pages.indexWhere((page) => page.source != null);
    final plainWidth = firstPdfPage == -1
        ? null
        : withPage(positions[firstPdfPage], geometryOf).shownWidth;
    for (var i = 0; i < pages.length; i++) {
      final spec = pages[i];
      if (spec.source != null) continue;
      final scale = plainWidth == null ? 1.0 : plainWidth / spec.width;
      final page = pdfium.FPDFPage_New(
        out,
        pageCount,
        spec.width * scale,
        spec.height * scale,
      );
      if (page == nullptr) fail('Could not create page $i');
      try {
        if (spec.hasOverlay) {
          insertOverlay(overlay, page, i, PdfAffine.scale(scale));
        }
        if (pdfium.FPDFPage_GenerateContent(page) == 0) {
          fail('Could not write page $i');
        }
      } finally {
        pdfium.FPDF_ClosePage(page);
      }
      positions[i] = pageCount++;
    }

    // 3. Draw the overlay on top of each imported page.
    for (var i = 0; i < pages.length; i++) {
      final spec = pages[i];
      if (spec.source == null) continue;
      final index = positions[i];

      // Bake the PDF's own annotations (highlights, form fields, ...) into
      // the page, as they are shown in Saber. Each step edits the page's
      // content streams directly, so the page is reloaded in between.
      withPage(index, (page) => pdfium.FPDFPage_Flatten(page, FLAT_NORMALDISPLAY));

      if (!spec.hasOverlay) continue;

      // Wrap the original content in q/Q so a page that leaves the
      // graphics state changed (transform, clip) can't move the overlay.
      withPage(index, (page) {
        final identity = arena<FS_MATRIX>();
        identity.ref
          ..a = 1
          ..b = 0
          ..c = 0
          ..d = 1
          ..e = 0
          ..f = 0;
        if (pdfium.FPDFPage_TransFormWithClip(page, identity, nullptr) == 0) {
          fail('Could not isolate the content of page $i');
        }
      });

      withPage(index, (page) {
        final geometry = geometryOf(page);
        final sourceRatio = geometry.shownWidth / geometry.shownHeight;
        final overlayRatio = spec.width / spec.height;
        if ((sourceRatio - overlayRatio).abs() / overlayRatio >
            PdfPageCompositor.aspectRatioTolerance) {
          fail('Page $i has a different shape than its PDF page');
        }
        final toOverlay = PdfPageCompositor.sourceToOverlay(
          left: geometry.left,
          bottom: geometry.bottom,
          right: geometry.right,
          top: geometry.top,
          rotation: geometry.rotation,
          overlayWidth: spec.width,
          overlayHeight: spec.height,
        );
        insertOverlay(overlay, page, i, toOverlay.inverse());
        if (pdfium.FPDFPage_GenerateContent(page) == 0) {
          fail('Could not write page $i');
        }
      });
    }

    // 4. Put the pages in the note's order.
    var inOrder = true;
    for (var i = 0; i < positions.length; i++) {
      if (positions[i] != i) inOrder = false;
    }
    if (!inOrder) {
      final order = arena<Int>(positions.length);
      for (var i = 0; i < positions.length; i++) {
        order[i] = positions[i];
      }
      if (pdfium.FPDF_MovePages(out, order, positions.length, 0) == 0) {
        fail('Could not reorder pages');
      }
    }
    if (pdfium.FPDF_GetPageCount(out) != pages.length) {
      fail('Output has ${pdfium.FPDF_GetPageCount(out)} pages, '
          'expected ${pages.length}');
    }

    return _save(pdfium, out, arena);
  } finally {
    if (out != nullptr) pdfium.FPDF_CloseDocument(out);
    for (final doc in openDocs) {
      pdfium.FPDF_CloseDocument(doc);
    }
    for (final buffer in buffers) {
      malloc.free(buffer);
    }
    arena.releaseAll();
  }
}

typedef _WriteBlockNative =
    Int Function(Pointer<FPDF_FILEWRITE_>, Pointer<Void>, UnsignedLong);

Uint8List _save(PDFium pdfium, FPDF_DOCUMENT doc, Arena arena) {
  final output = BytesBuilder();
  int writeBlock(Pointer<FPDF_FILEWRITE_> self, Pointer<Void> data, int size) {
    output.add(data.cast<Uint8>().asTypedList(size));
    return 1;
  }

  final callable = NativeCallable<_WriteBlockNative>.isolateLocal(
    writeBlock,
    exceptionalReturn: 0,
  );
  try {
    final fileWrite = arena<FPDF_FILEWRITE>();
    fileWrite.ref
      ..version = 1
      ..WriteBlock = callable.nativeFunction;
    if (pdfium.FPDF_SaveAsCopy(doc, fileWrite, FPDF_NO_INCREMENTAL) == 0) {
      throw const PdfCompositorException('Could not save the PDF');
    }
  } finally {
    callable.close();
  }
  return output.takeBytes();
}
