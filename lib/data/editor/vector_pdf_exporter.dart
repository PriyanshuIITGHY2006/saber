import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FileImage, MemoryImage;
import 'package:image/image.dart' as im;
import 'package:logging/logging.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pool/pool.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/pdf_page_compositor.dart';
import 'package:saber/data/prefs.dart';

/// Exports notes built on imported PDFs by keeping the original PDF pages
/// and adding only the user's own content on top.
///
/// Compared to [EditorExporter.generatePdf], which turns every PDF page
/// into an image, the output keeps the PDF's text (selectable and
/// searchable), stays sharp at any zoom, and is usually far smaller.
///
/// Pen and highlighter strokes, pasted photos and page numbers are drawn
/// as vector graphics or embedded as-is. Only typed text, pencil strokes
/// and images that can't be embedded (SVGs, PDFs) still need a
/// screenshot, which is transparent and layered over the original page.
/// Pages without any of those aren't screenshotted at all.
abstract final class VectorPdfExporter {
  static final log = Logger('VectorPdfExporter');

  /// Same as the canvas' page number, see `CanvasPainter`.
  static const double _pageIndicatorFontSize = 20;
  static const double _pageIndicatorPadding = 5;

  /// Whether [coreInfo] has any page with an imported PDF as background.
  static bool canExport(EditorCoreInfo coreInfo) {
    if (kIsWeb) return false;
    return coreInfo.pages.any((page) => page.backgroundImage is PdfEditorImage);
  }

  /// Pencil strokes use a texture shader, so they can't be drawn as
  /// vectors. Everything else drawn by the user can.
  static bool _isPencil(Stroke stroke) => stroke.toolId == .pencil;

  /// Content on [page] that only a screenshot can reproduce.
  static bool _hasRasterOnlyContent(EditorPage page) {
    if (!page.quill.controller.document.isEmpty()) return true;
    return page.strokes.any(_isPencil);
  }

  /// [page]'s images as embeddable PDF images, or null if any of them
  /// can't be embedded directly (e.g. SVGs, PDFs or cropped images).
  static Future<List<(EditorImage, pw.ImageProvider)>?> _embeddableImages(
    EditorPage page,
  ) async {
    final result = <(EditorImage, pw.ImageProvider)>[];
    for (final image in page.images) {
      final pdfImage = await _pdfImageFor(image);
      if (pdfImage == null) return null;
      result.add((image, pdfImage));
    }
    return result;
  }

  static Future<pw.ImageProvider?> _pdfImageFor(EditorImage image) async {
    if (image is! PngEditorImage) return null;
    if (image.srcRect.topLeft != ui.Offset.zero) return null;
    if (image.dstRect.width <= 0 || image.dstRect.height <= 0) return null;

    final provider = image.imageProvider;
    final Uint8List bytes;
    if (provider is MemoryImage) {
      bytes = provider.bytes;
    } else if (provider is FileImage) {
      bytes = await provider.file.readAsBytes();
    } else {
      return null;
    }
    if (bytes.isEmpty) return null;

    try {
      // Embeds the original file (e.g. a JPEG as-is), at full quality.
      return pw.MemoryImage(bytes);
    } catch (e) {
      log.fine('Image ${image.id} will be rasterized instead: $e');
      return null;
    }
  }

  static Future<Uint8List> _readPdfBytes(PdfEditorImage image) async {
    final bytes = image.pdfBytes;
    if (bytes != null && bytes.isNotEmpty) return bytes;
    final file = image.pdfFile;
    if (file == null) throw StateError('PDF background has no data');
    return file.readAsBytes();
  }

  /// Throws if the export fails; see [EditorExporter.generatePdfBytes]
  /// for the version that falls back to rasterizing.
  static Future<Uint8List> export(EditorCoreInfo coreInfo) async {
    final stopwatch = Stopwatch()..start();

    if (coreInfo.pages.isNotEmpty && coreInfo.pages.last.isEmpty) {
      // don't export the empty last page, same as [EditorExporter.generatePdf]
      coreInfo = coreInfo.copyWith(
        pages: coreInfo.pages.toList()..removeLast(),
      );
    }
    final pages = coreInfo.pages;
    if (pages.isEmpty) throw StateError('Nothing to export');

    // Collect the source PDFs, reading each file only once.
    final sources = <Uint8List>[];
    final sourceIndices = <Object, int>{};
    final pdfBackgrounds = <PdfEditorImage?>[];
    for (final page in pages) {
      final background = page.backgroundImage;
      if (background is! PdfEditorImage) {
        pdfBackgrounds.add(null);
        continue;
      }
      pdfBackgrounds.add(background);
      final key = background.pdfFile?.path ?? background.pdfBytes ?? background;
      if (sourceIndices.containsKey(key)) continue;
      sourceIndices[key] = sources.length;
      sources.add(await _readPdfBytes(background));
    }

    // Decide per page what can be drawn as vectors. PDF pages are drawn
    // entirely as vectors unless they have typed text, pencil strokes or
    // images that can't be embedded. Plain pages still need a screenshot
    // for their background pattern.
    final embeddedImages = <List<(EditorImage, pw.ImageProvider)>?>[];
    final needsScreenshot = <bool>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (pdfBackgrounds[i] == null) {
        embeddedImages.add(null);
        needsScreenshot.add(true);
      } else if (_hasRasterOnlyContent(page)) {
        embeddedImages.add(null);
        needsScreenshot.add(true);
      } else {
        final images = await _embeddableImages(page);
        embeddedImages.add(images);
        needsScreenshot.add(images == null);
      }
    }

    final pool = Pool((Platform.numberOfProcessors ~/ 2).clamp(1, 4));
    final screenshots = await Future.wait(
      List.generate(pages.length, (pageIndex) {
        if (!needsScreenshot[pageIndex]) {
          return Future<im.Image?>.value(null);
        }
        return pool.withResource(
          () => _screenshot(
            coreInfo: coreInfo,
            pageIndex: pageIndex,
            transparent: pdfBackgrounds[pageIndex] != null,
          ),
        );
      }),
    );

    final defaultBackground = PdfColor.fromInt(
      coreInfo.backgroundColor?.toARGB32() ??
          InnerCanvas.defaultBackgroundColor.toARGB32(),
    ).flatten();
    final printPageIndicators = stows.printPageIndicators.value;

    final overlay = pw.Document();
    final specs = <PdfCompositePage>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final width = page.size.width;
      final height = page.size.height;
      final screenshot = screenshots[i];
      final pdfBackground = pdfBackgrounds[i];
      final images = embeddedImages[i] ?? const [];
      // A screenshot already contains the page number (drawn by the canvas).
      final drawPageIndicator = printPageIndicators && screenshot == null;

      overlay.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(width, height),
          build: (pw.Context context) => pw.SizedBox(
            width: width,
            height: height,
            child: pw.Stack(
              children: [
                pw.CustomPaint(
                  foregroundPainter: (PdfGraphics graphics, PdfPoint size) {
                    // Same order as the canvas: highlighter underneath.
                    EditorExporter.drawHighlighterStrokes(
                      graphics,
                      strokes: page.strokes,
                      pageHeight: height,
                    );
                    EditorExporter.drawVectorStrokes(
                      graphics,
                      strokes: page.strokes,
                      pageHeight: height,
                      // Saber always shows PDF pages on white paper
                      backgroundColor: pdfBackground != null
                          ? PdfColors.white
                          : defaultBackground,
                    );
                  },
                  child: screenshot != null
                      ? pw.Image(
                          pw.ImageImage(screenshot),
                          width: width,
                          height: height,
                        )
                      : pw.Stack(
                          children: [
                            pw.SizedBox(width: width, height: height),
                            for (final (image, pdfImage) in images)
                              pw.Positioned(
                                left: image.dstRect.left,
                                top: image.dstRect.top,
                                child: pw.Image(
                                  pdfImage,
                                  width: image.dstRect.width,
                                  height: image.dstRect.height,
                                  fit: pw.BoxFit.fill,
                                ),
                              ),
                          ],
                        ),
                ),
                if (drawPageIndicator)
                  pw.Positioned(
                    right: _pageIndicatorPadding,
                    bottom: _pageIndicatorPadding,
                    child: pw.Opacity(
                      opacity: 0.5,
                      child: pw.Text(
                        '${i + 1} / ${pages.length}',
                        style: const pw.TextStyle(
                          fontSize: _pageIndicatorFontSize,
                          color: PdfColors.black,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

      specs.add(
        PdfCompositePage(
          width: width,
          height: height,
          source: pdfBackground == null
              ? null
              : sourceIndices[pdfBackground.pdfFile?.path ??
                    pdfBackground.pdfBytes ??
                    pdfBackground],
          sourcePage: pdfBackground?.pdfPage ?? 0,
          hasOverlay:
              pdfBackground == null ||
              screenshot != null ||
              page.strokes.isNotEmpty ||
              images.isNotEmpty ||
              drawPageIndicator,
        ),
      );
    }

    final overlayBytes = await overlay.save();
    final result = await PdfPageCompositor.compose(
      overlay: overlayBytes,
      sources: sources,
      pages: specs,
    );

    log.info(
      'Exported ${pages.length} pages '
      '(${screenshots.nonNulls.length} screenshots) '
      'to ${result.length ~/ 1024} KB in ${stopwatch.elapsedMilliseconds} ms',
    );
    return result;
  }

  static Future<im.Image> _screenshot({
    required EditorCoreInfo coreInfo,
    required int pageIndex,
    required bool transparent,
  }) async {
    final uiImage = await EditorExporter.screenshotPage(
      coreInfo: coreInfo,
      pageIndex: pageIndex,
      transparentBackground: transparent,
      // Highlighter and pen strokes are drawn as vectors on top.
      strokeFilter: _isPencil,
    );
    try {
      // PDF soft masks expect straight (not premultiplied) alpha,
      // otherwise semi-transparent pixels come out too dark.
      final byteData = await uiImage.toByteData(
        format: transparent
            ? ui.ImageByteFormat.rawStraightRgba
            : ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) throw StateError('Failed to read screenshot');
      return im.Image.fromBytes(
        width: uiImage.width,
        height: uiImage.height,
        bytes: byteData.buffer,
        order: im.ChannelOrder.rgba,
      );
    } finally {
      uiImage.dispose();
    }
  }
}
