import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_quill/flutter_quill.dart';
import 'package:image/image.dart' as im;
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pool/pool.dart';
import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/components/canvas/_rectangle_stroke.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/vector_pdf_exporter.dart';
import 'package:saber/data/is_this_a_test.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:screenshot/screenshot.dart';

abstract class EditorExporter {
  /// Most* strokes can be drawn to the PDF canvas as vector graphics.
  /// This function returns true if [stroke] is one of those strokes.
  ///
  /// Strokes that can't be drawn as vector graphics include:
  /// - Highlighter strokes, because PDFs don't support transparency
  /// - Pencil strokes, which need a special shader to look correct
  static bool shouldRasterizeStroke(Stroke stroke) {
    return stroke.toolId == .highlighter || stroke.toolId == .pencil;
  }

  static final log = Logger('EditorExporter');

  /// Exports [coreInfo] as PDF bytes.
  ///
  /// Notes built on imported PDFs keep the original PDF pages (with their
  /// text and vector graphics) and only add the user's writing on top,
  /// see [VectorPdfExporter]. Everything else, and any note where that
  /// fails, uses [generatePdf].
  static Future<Uint8List> generatePdfBytes(
    EditorCoreInfo coreInfo, [
    BuildContext? context,
  ]) async {
    if (VectorPdfExporter.canExport(coreInfo)) {
      try {
        return await VectorPdfExporter.export(coreInfo);
      } catch (e, st) {
        log.warning(
          'Vector PDF export failed, falling back to rasterized export: $e',
          e,
          st,
        );
      }
    }
    final pdf = await generatePdf(coreInfo, context);
    return pdf.save();
  }

  static Future<pw.Document> generatePdf(
    EditorCoreInfo coreInfo, [
    BuildContext? context,
  ]) async {
    if (coreInfo.pages.isNotEmpty && coreInfo.pages.last.isEmpty) {
      // don't export the empty last page
      coreInfo = coreInfo.copyWith(
        pages: coreInfo.pages.toList()..removeLast(),
      );
    }

    final pdf = pw.Document();

    // screenshot each page
    final pool = Pool((Platform.numberOfProcessors ~/ 2).clamp(1, 4));
    final pageScreenshots = await Future.wait(
      List.generate(
        coreInfo.pages.length,
        (pageIndex) => pool.withResource(() async {
          final uiImage = await screenshotPage(
            coreInfo: coreInfo,
            pageIndex: pageIndex,
          );
          final byteData = await uiImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          assert(
            byteData != null,
            'Judging by the code, this should never be null.',
          );
          final imImage = im.Image.fromBytes(
            width: uiImage.width,
            height: uiImage.height,
            bytes: byteData!.buffer,
            order: im.ChannelOrder.rgba,
          );
          uiImage.dispose();
          return imImage;
        }),
      ),
    );

    for (int pageIndex = 0; pageIndex < pageScreenshots.length; ++pageIndex) {
      final page = coreInfo.pages[pageIndex];
      final pageSize = page.size;
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(pageSize.width, pageSize.height),
          build: (pw.Context context) {
            return pw.SizedBox(
              width: pageSize.width,
              height: pageSize.height,
              child: pw.CustomPaint(
                foregroundPainter: (PdfGraphics pdfGraphics, PdfPoint size) {
                  final backgroundColor = PdfColor.fromInt(
                    coreInfo.backgroundColor?.toARGB32() ??
                        InnerCanvas.defaultBackgroundColor.toARGB32(),
                  ).flatten();
                  drawVectorStrokes(
                    pdfGraphics,
                    strokes: page.strokes,
                    pageHeight: pageSize.height,
                    backgroundColor: backgroundColor,
                  );
                },
                child: pw.Image(
                  pw.ImageImage(pageScreenshots[pageIndex]),
                  width: pageSize.width,
                  height: pageSize.height,
                ),
              ),
            );
          },
        ),
      );
    }

    return pdf;
  }

  /// Draws every stroke that doesn't need rasterizing (see
  /// [shouldRasterizeStroke]) as vector graphics.
  ///
  /// Stroke colors are flattened onto [backgroundColor] because
  /// the strokes are drawn fully opaque.
  static void drawVectorStrokes(
    PdfGraphics pdfGraphics, {
    required Iterable<Stroke> strokes,
    required double pageHeight,
    required PdfColor backgroundColor,
  }) {
    for (final stroke in strokes) {
      if (shouldRasterizeStroke(stroke)) continue;

      final strokeColor = PdfColor.fromInt(
        stroke.color.toARGB32(),
      ).flatten(background: backgroundColor);

      /// Whether we need to fill the shape, or draw its stroke
      final bool shouldFillShape;
      if (stroke is CircleStroke) {
        shouldFillShape = false;
        pdfGraphics.drawEllipse(
          stroke.center.dx,
          pageHeight - stroke.center.dy,
          stroke.radius,
          stroke.radius,
          clockwise: false,
        );
      } else if (stroke is RectangleStroke) {
        shouldFillShape = false;
        final strokeSize = stroke.options.size;
        pdfGraphics.drawRRect(
          stroke.rect.left,
          pageHeight - stroke.rect.bottom,
          stroke.rect.width,
          stroke.rect.height,
          strokeSize / 4,
          strokeSize / 4,
        );
      } else {
        shouldFillShape = true;
        pdfGraphics.drawShape(stroke.toSvgPath());
      }

      if (shouldFillShape) {
        // fill
        pdfGraphics.setFillColor(strokeColor);
        pdfGraphics.fillPath();
      } else {
        // stroke
        pdfGraphics.setStrokeColor(strokeColor);
        pdfGraphics.setLineWidth(stroke.options.size);
        pdfGraphics.strokePath();
      }
    }
  }

  /// Draws highlighter strokes as vector graphics, the way the canvas
  /// does: strokes of the same color (in a row) are merged into one shape,
  /// so overlaps don't get darker, then blended with "darken" at
  /// [Highlighter.alpha] opacity.
  ///
  /// Call this before [drawVectorStrokes]: the canvas draws highlighter
  /// strokes underneath all other strokes.
  static void drawHighlighterStrokes(
    PdfGraphics pdfGraphics, {
    required Iterable<Stroke> strokes,
    required double pageHeight,
  }) {
    final highlights = strokes
        .where((stroke) => stroke.toolId == .highlighter)
        .toList(growable: false);
    var start = 0;
    while (start < highlights.length) {
      final color = highlights[start].color.withValues(alpha: 1).toARGB32();
      var end = start + 1;
      while (end < highlights.length &&
          highlights[end].color.withValues(alpha: 1).toARGB32() == color) {
        end++;
      }

      final path = StringBuffer();
      for (final stroke in highlights.sublist(start, end)) {
        _appendNormalizedPolygon(path, stroke.highQualityPolygon, pageHeight);
      }
      if (path.isNotEmpty) {
        pdfGraphics
          ..saveContext()
          ..setGraphicState(
            PdfGraphicState(
              opacity: Highlighter.alpha / 255,
              blendMode: PdfBlendMode.darken,
            ),
          )
          ..setFillColor(PdfColor.fromInt(color))
          ..drawShape(path.toString())
          ..fillPath()
          ..restoreContext();
      }
      start = end;
    }
  }

  /// Appends [polygon] to [path] as a closed SVG subpath, wound
  /// counter-clockwise, so that a non-zero fill of several polygons
  /// covers their union.
  static void _appendNormalizedPolygon(
    StringBuffer path,
    List<Offset> polygon,
    double pageHeight,
  ) {
    final points = polygon.where((point) => point.isFinite).toList();
    if (points.length < 3) return;

    var doubleArea = 0.0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      doubleArea += a.dx * b.dy - b.dx * a.dy;
    }
    final ordered = doubleArea < 0 ? points.reversed.toList() : points;

    path.write('M');
    path.writeAll(
      ordered.map((point) => '${point.dx} ${pageHeight - point.dy}'),
      'L',
    );
    path.write('Z');
  }

  /// Returns a screenshot of the page at [pageIndex] in [coreInfo].
  ///
  /// Note that screenshots do not include most* strokes
  /// because they're added separately to the PDF as vector graphics.
  /// See [shouldRasterizeStroke] for more details, or set
  /// [rasterizeAllStrokes] to true to include all strokes in the screenshot.
  ///
  /// If [transparentBackground] is true, the page's background image,
  /// background color and background pattern are left out, so the
  /// screenshot can be layered on top of the original background.
  ///
  /// If [strokeFilter] is given, only the strokes it accepts (out of the
  /// ones that would otherwise be included) are drawn.
  ///
  /// You must dispose this image when you're done.
  static Future<ui.Image> screenshotPage({
    required EditorCoreInfo coreInfo,
    required int pageIndex,
    bool rasterizeAllStrokes = false,
    bool transparentBackground = false,
    bool Function(Stroke stroke)? strokeFilter,
    Size? targetSize,
    double? cropHeight,
    double pixelRatio = 2,
  }) async {
    var page = coreInfo.pages[pageIndex].cloneForRasterization(
      rasterizeAllStrokes: rasterizeAllStrokes,
    );
    if (transparentBackground || strokeFilter != null) {
      page = EditorPage(
        size: page.size,
        strokes: strokeFilter == null
            ? page.strokes
            : page.strokes.where(strokeFilter).toList(),
        images: page.images,
        quill: page.quill,
        backgroundImage: transparentBackground ? null : page.backgroundImage,
      );
    }

    final imagesToLoad = [
      ?page.backgroundImage,
      ...page.images,
    ].where((image) => !image.loadedIn).toList(growable: false);
    await Future.wait(imagesToLoad.map((image) => image.loadIn()))
        .timeout(const Duration(seconds: 10), onTimeout: () => const []);

    try {
      targetSize ??= page.size;
      coreInfo = coreInfo.copyWith(
        pages: [for (var i = 0; i < coreInfo.pages.length; ++i) page],
        backgroundColor: transparentBackground ? const Color(0x00000000) : null,
        backgroundPattern: transparentBackground
            ? CanvasBackgroundPattern.none
            : null,
      );
      return await ScreenshotController.widgetToUiImage(
        EditorExporterTheme(
          targetSize: targetSize,
          child: CanvasPreview(
            pageIndex: pageIndex,
            height: cropHeight,
            coreInfo: coreInfo,
          ),
        ),
        pixelRatio: pixelRatio,
        targetSize: targetSize,
        delay: isThisATest ? .zero : const Duration(milliseconds: 200),
      );
    } finally {
      for (final image in imagesToLoad) unawaited(image.loadOut());
      page.disposeClonedData();
    }
  }
}

/// Applies a consistent theme to its [child] so that exports
/// look the same regardless of the user's current theme or device.
class EditorExporterTheme extends StatelessWidget {
  const new({super.key, required this.targetSize, required this.child});

  final Size targetSize;
  final Widget child;

  static final theme = ThemeData(
    brightness: .light,
    colorScheme: const ColorScheme.light(
      primary: Colors.blue,
      secondary: Colors.red,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(size: targetSize),
      child: Localizations(
        // needed to avoid errors with Quill, but not actually used
        locale: const Locale('en', 'US'),
        delegates: const [
          ...GlobalMaterialLocalizations.delegates,
          FlutterQuillLocalizations.delegate,
        ],
        child: Theme(
          data: theme,
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium!,
            child: SizedBox(
              width: targetSize.width,
              height: targetSize.height,
              child: FittedBox(
                fit: BoxFit.cover,
                alignment: Alignment.topLeft,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
