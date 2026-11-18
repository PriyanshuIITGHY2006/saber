import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as im;
import 'package:logging/logging.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pool/pool.dart';
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
/// Pen strokes are drawn as vector graphics. Things that can't be drawn
/// as vectors (highlighter, pencil, typed text, pasted images) go into
/// a transparent screenshot layered over the page, and pages that have
/// none of them aren't screenshotted at all.
abstract final class VectorPdfExporter {
  static final log = Logger('VectorPdfExporter');

  /// Whether [coreInfo] has any page with an imported PDF as background.
  static bool canExport(EditorCoreInfo coreInfo) {
    if (kIsWeb) return false;
    return coreInfo.pages.any((page) => page.backgroundImage is PdfEditorImage);
  }

  /// Whether [page] has content that has to be rasterized.
  static bool _needsScreenshot(EditorPage page) {
    // Page numbers are drawn by the canvas
    if (stows.printPageIndicators.value) return true;
    if (page.images.isNotEmpty) return true;
    if (!page.quill.controller.document.isEmpty()) return true;
    return page.strokes.any(EditorExporter.shouldRasterizeStroke);
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

    // Screenshot only the pages that need it.
    final pool = Pool((Platform.numberOfProcessors ~/ 2).clamp(1, 4));
    final screenshots = await Future.wait(
      List.generate(pages.length, (pageIndex) {
        final hasPdfBackground = pdfBackgrounds[pageIndex] != null;
        if (hasPdfBackground && !_needsScreenshot(pages[pageIndex])) {
          return Future<im.Image?>.value(null);
        }
        return pool.withResource(
          () => _screenshot(
            coreInfo: coreInfo,
            pageIndex: pageIndex,
            transparent: hasPdfBackground,
          ),
        );
      }),
    );

    final defaultBackground = PdfColor.fromInt(
      coreInfo.backgroundColor?.toARGB32() ??
          InnerCanvas.defaultBackgroundColor.toARGB32(),
    ).flatten();

    final overlay = pw.Document();
    final specs = <PdfCompositePage>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final pageSize = page.size;
      final screenshot = screenshots[i];
      final pdfBackground = pdfBackgrounds[i];
      final hasVectorStrokes = page.strokes.any(
        (stroke) => !EditorExporter.shouldRasterizeStroke(stroke),
      );

      overlay.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(pageSize.width, pageSize.height),
          build: (pw.Context context) => pw.SizedBox(
            width: pageSize.width,
            height: pageSize.height,
            child: pw.CustomPaint(
              foregroundPainter: (PdfGraphics graphics, PdfPoint size) {
                EditorExporter.drawVectorStrokes(
                  graphics,
                  strokes: page.strokes,
                  pageHeight: pageSize.height,
                  // Saber always shows PDF pages on white paper
                  backgroundColor: pdfBackground != null
                      ? PdfColors.white
                      : defaultBackground,
                );
              },
              child: screenshot == null
                  ? pw.SizedBox(width: pageSize.width, height: pageSize.height)
                  : pw.Image(
                      pw.ImageImage(screenshot),
                      width: pageSize.width,
                      height: pageSize.height,
                    ),
            ),
          ),
        ),
      );

      specs.add(
        PdfCompositePage(
          width: pageSize.width,
          height: pageSize.height,
          source: pdfBackground == null
              ? null
              : sourceIndices[pdfBackground.pdfFile?.path ??
                    pdfBackground.pdfBytes ??
                    pdfBackground],
          sourcePage: pdfBackground?.pdfPage ?? 0,
          hasOverlay:
              pdfBackground == null || screenshot != null || hasVectorStrokes,
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
