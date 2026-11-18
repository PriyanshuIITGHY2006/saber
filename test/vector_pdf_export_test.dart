import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pdfw;
// ignore: implementation_imports
import 'package:pdf/src/pdf/format/array.dart' as pdfw_format;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/pdf_page_compositor.dart';
import 'package:saber/data/editor/vector_pdf_exporter.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/stroke_properties.dart';

import 'utils/test_mock_channel_handlers.dart';

/// A page of the generated "lecture" PDF.
class _SourcePage {
  const _SourcePage(this.text, this.rotation, [this.cropBox]);

  final String text;
  final pdfw.PdfPageRotation rotation;

  /// left, bottom, right, top
  final List<double>? cropBox;

  static const mediaWidth = 300.0;
  static const mediaHeight = 400.0;

  double get boxWidth =>
      cropBox == null ? mediaWidth : cropBox![2] - cropBox![0];
  double get boxHeight =>
      cropBox == null ? mediaHeight : cropBox![3] - cropBox![1];
  bool get isSideways =>
      rotation == pdfw.PdfPageRotation.rotate90 ||
      rotation == pdfw.PdfPageRotation.rotate270;
  double get shownWidth => isSideways ? boxHeight : boxWidth;
  double get shownHeight => isSideways ? boxWidth : boxHeight;
}

const _sourcePages = [
  _SourcePage('Alpha page', pdfw.PdfPageRotation.none),
  _SourcePage('Beta page', pdfw.PdfPageRotation.rotate90),
  _SourcePage('Gamma page', pdfw.PdfPageRotation.rotate180, [20, 30, 280, 380]),
  _SourcePage('Delta page', pdfw.PdfPageRotation.rotate270, [10, 15, 290, 395]),
];

Future<Uint8List> _buildSourcePdf() async {
  final doc = pdfw.PdfDocument();
  final font = pdfw.PdfFont.helvetica(doc);
  for (final spec in _sourcePages) {
    final page = pdfw.PdfPage(
      doc,
      pageFormat: const pdfw.PdfPageFormat(
        _SourcePage.mediaWidth,
        _SourcePage.mediaHeight,
      ),
      rotate: spec.rotation,
    );
    if (spec.cropBox != null) {
      page.params['/CropBox'] = pdfw_format.PdfArray.fromNum(spec.cropBox!);
    }
    page.getGraphics()
      ..setFillColor(pdfw.PdfColors.black)
      ..drawString(font, 20, spec.text, 100, 200);
  }
  return doc.save();
}

/// Overlay page in Saber coordinates with a black square whose
/// top-left corner is 100pt from the top-left of the page.
Future<Uint8List> _buildOverlayPdf(List<Size> sizes) async {
  final doc = pdfw.PdfDocument();
  for (final size in sizes) {
    final page = pdfw.PdfPage(
      doc,
      pageFormat: pdfw.PdfPageFormat(size.width, size.height),
    );
    page.getGraphics()
      ..setFillColor(pdfw.PdfColors.black)
      ..drawRect(100, size.height - 200, 100, 100)
      ..fillPath();
  }
  return doc.save();
}

/// Average brightness (0-255) at a fraction of the rendered page.
int _brightnessAt(PdfImage image, double fx, double fy) {
  final x = (fx * image.width).floor().clamp(0, image.width - 1);
  final y = (fy * image.height).floor().clamp(0, image.height - 1);
  final o = (y * image.width + x) * 4;
  final p = image.pixels;
  return (p[o] + p[o + 1] + p[o + 2]) ~/ 3;
}

Future<PdfImage> _render(PdfPage page) async {
  final width = (page.width * 2).round();
  final height = (page.height * 2).round();
  final image = await page.render(
    width: width,
    height: height,
    fullWidth: width.toDouble(),
    fullHeight: height.toDouble(),
    backgroundColor: 0xffffffff,
  );
  return image!;
}

void main() {
  group('sourceToOverlay', () {
    const overlayWidth = 1000.0;
    // A page box that doesn't start at the origin.
    const left = 10.0, bottom = 20.0, right = 310.0, top = 420.0;

    PdfAffine transform(int rotation) {
      final sideways = rotation.isOdd;
      final shownWidth = sideways ? top - bottom : right - left;
      final shownHeight = sideways ? right - left : top - bottom;
      return PdfPageCompositor.sourceToOverlay(
        left: left,
        bottom: bottom,
        right: right,
        top: top,
        rotation: rotation,
        overlayWidth: overlayWidth,
        overlayHeight: overlayWidth * shownHeight / shownWidth,
      );
    }

    void expectPoint((double, double) actual, (double, double) expected) {
      expect(actual.$1, closeTo(expected.$1, 1e-6));
      expect(actual.$2, closeTo(expected.$2, 1e-6));
    }

    test('no rotation: top-left stays top-left', () {
      final t = transform(0);
      expectPoint(t.apply(left, top), (0, overlayWidth * 4 / 3));
      expectPoint(t.apply(right, bottom), (overlayWidth, 0));
    });

    test('90°: top-left goes to the top-right', () {
      final t = transform(1);
      final h = overlayWidth * 300 / 400;
      expectPoint(t.apply(left, top), (overlayWidth, h));
      expectPoint(t.apply(left, bottom), (0, h));
      expectPoint(t.apply(right, bottom), (0, 0));
    });

    test('180°: top-left goes to the bottom-right', () {
      final t = transform(2);
      expectPoint(t.apply(left, top), (overlayWidth, 0));
      expectPoint(t.apply(right, bottom), (0, overlayWidth * 4 / 3));
    });

    test('270°: top-left goes to the bottom-left', () {
      final t = transform(3);
      final h = overlayWidth * 300 / 400;
      expectPoint(t.apply(left, top), (0, 0));
      expectPoint(t.apply(right, top), (0, h));
      expectPoint(t.apply(right, bottom), (overlayWidth, h));
    });

    test('inverse undoes the transform', () {
      for (var rotation = 0; rotation < 4; rotation++) {
        final t = transform(rotation);
        final back = t.inverse();
        final (x, y) = t.apply(123, 234);
        expectPoint(back.apply(x, y), (123, 234));
      }
    });

    test('letterboxes when the shapes differ', () {
      final t = PdfPageCompositor.sourceToOverlay(
        left: 0,
        bottom: 0,
        right: 100,
        top: 100,
        rotation: 0,
        overlayWidth: 200,
        overlayHeight: 400,
      );
      // Square page in a tall overlay: scaled to 200 wide, centered.
      expectPoint(t.apply(0, 0), (0, 100));
      expectPoint(t.apply(100, 100), (200, 300));
    });
  });

  group('PDFium', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    FlavorConfig.setup();

    setUpAll(() async {
      final tmp = await Directory.systemTemp.createTemp('pdfrx_test');
      await pdfrxInitialize(tmpPath: tmp.path);
      await FileManager.init(shouldWatchRootDirectory: false);
    });

    test('compose keeps the original pages and lines up the overlay', () async {
      final source = await _buildSourcePdf();

      // Note order: Alpha, a plain page, Beta, Gamma, Delta, Alpha again.
      final noteSourcePages = [0, null, 1, 2, 3, 0];
      final sizes = [
        for (final index in noteSourcePages)
          index == null
              ? const Size(1000, 1400)
              : Size(
                  1000,
                  1000 *
                      _sourcePages[index].shownHeight /
                      _sourcePages[index].shownWidth,
                ),
      ];
      final overlay = await _buildOverlayPdf(sizes);

      final result = await PdfPageCompositor.compose(
        overlay: overlay,
        sources: [source],
        pages: [
          for (var i = 0; i < noteSourcePages.length; i++)
            PdfCompositePage(
              width: sizes[i].width,
              height: sizes[i].height,
              source: noteSourcePages[i] == null ? null : 0,
              sourcePage: noteSourcePages[i] ?? 0,
            ),
        ],
      );

      final doc = await PdfDocument.openData(result);
      addTearDown(doc.dispose);
      expect(doc.pages.length, noteSourcePages.length);

      for (var i = 0; i < noteSourcePages.length; i++) {
        final page = doc.pages[i];
        final sourceIndex = noteSourcePages[i];
        final text = (await page.loadText())?.fullText ?? '';

        if (sourceIndex == null) {
          // Plain pages take the width of the first PDF page.
          expect(page.width, closeTo(300, 0.5), reason: 'page $i width');
          expect(page.height, closeTo(420, 0.5), reason: 'page $i height');
          expect(text.trim(), isEmpty, reason: 'page $i text');
        } else {
          final spec = _sourcePages[sourceIndex];
          expect(page.width, closeTo(spec.shownWidth, 0.5), reason: 'page $i');
          expect(page.height, closeTo(spec.shownHeight, 0.5), reason: 'page $i');
          expect(text, contains(spec.text), reason: 'page $i keeps its text');
        }

        // The square sits 100-200pt from the top-left of a 1000pt-wide
        // Saber page, so its middle is at 15% across and 150pt down.
        final image = await _render(page);
        try {
          final fy = 150 / sizes[i].height;
          expect(
            _brightnessAt(image, 0.15, fy),
            lessThan(80),
            reason: 'page $i should have the overlay square at the top-left',
          );
          expect(
            _brightnessAt(image, 0.92, 0.97),
            greaterThan(200),
            reason: 'page $i bottom-right corner should be blank',
          );
        } finally {
          image.dispose();
        }
      }
    });

    test('compose rejects mismatched page shapes', () async {
      final source = await _buildSourcePdf();
      final overlay = await _buildOverlayPdf([const Size(1000, 1000)]);
      await expectLater(
        PdfPageCompositor.compose(
          overlay: overlay,
          sources: [source],
          pages: const [
            PdfCompositePage(width: 1000, height: 1000, source: 0),
          ],
        ),
        throwsA(anything),
      );
    });

    testWidgets('VectorPdfExporter exports a note on a PDF', (tester) async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(
        ServicesBinding.rootIsolateToken!,
      );
      StrokeOptionsExtension.setDefaults();
      FileManager.shouldUseRawFilePath = true;
      EditorImage.shouldLoadOutImmediately = true;

      const path = 'test/sbn_examples/v18_highlighter';
      final result = await tester.runAsync(() async {
        final coreInfo = await EditorCoreInfo.loadFromFileContents(
          bsonBytes: File('$path.sbn2').readAsBytesSync(),
          path: path,
          onlyFirstPage: true,
        );
        final page = coreInfo.pages.first;

        final doc = pdfw.PdfDocument();
        final pdfPage = pdfw.PdfPage(
          doc,
          pageFormat: pdfw.PdfPageFormat(page.size.width, page.size.height),
        );
        pdfPage.getGraphics()
          ..setFillColor(pdfw.PdfColors.black)
          ..drawString(
            pdfw.PdfFont.helvetica(doc),
            30,
            'Lecture slide text',
            50,
            50,
          );
        final pdfBytes = await doc.save();

        page.backgroundImage = PdfEditorImage(
          id: 9999,
          assetCache: coreInfo.assetCache,
          pdfBytes: pdfBytes,
          pdfFile: null,
          pdfPage: 0,
          pageIndex: 0,
          pageSize: page.size,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
          naturalSize: page.size,
        );

        expect(VectorPdfExporter.canExport(coreInfo), isTrue);
        return VectorPdfExporter.export(coreInfo);
      });

      expect(result, isNotNull);
      final text = await tester.runAsync(() async {
        final doc = await PdfDocument.openData(result!);
        try {
          expect(doc.pages.length, 1);
          return (await doc.pages.first.loadText())?.fullText;
        } finally {
          await doc.dispose();
        }
      });
      expect(text, contains('Lecture slide text'));
    });
  });
}
