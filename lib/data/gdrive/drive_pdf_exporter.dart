import 'dart:async';

import 'package:logging/logging.dart';
import 'package:mutex/mutex.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/gdrive/drive_syncer.dart';
import 'package:saber/data/gdrive/drive_tree.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/editor/editor.dart';

/// Keeps a PDF copy of every note in the `Saber Notes (PDF)` folder
/// on Drive, mirroring the note's folders: `/Maths/Week 1.sbn2`
/// becomes `Saber Notes (PDF)/Maths/Week 1.pdf`.
///
/// Exports are debounced, so a note is rendered once you stop writing
/// rather than on every autosave. Notes waiting to be exported are
/// remembered across restarts in [stows.gdrivePdfPending].
abstract final class DrivePdfExporter {
  static final log = Logger('DrivePdfExporter');

  /// How long to wait after the last edit before exporting.
  static const debounce = Duration(seconds: 20);

  static final _timers = <String, Timer>{};
  static final _lock = Mutex();

  static bool get isActive => DriveSync.isActive && stows.gdriveExportPdfs.value;

  /// Called for every changed file; only note files (not their assets
  /// or previews) schedule an export.
  static void onLocalChange(String relativePath) {
    if (!isActive) return;
    if (!relativePath.endsWith(Editor.extension)) return;
    final notePath = relativePath.substring(
      0,
      relativePath.length - Editor.extension.length,
    );
    if (Editor.isReservedPath(notePath)) return;

    stows.gdrivePdfPending.value.add(notePath);
    stows.gdrivePdfPending.notifyListeners();

    _timers.remove(notePath)?.cancel();
    _timers[notePath] = Timer(debounce, () {
      _timers.remove(notePath);
      unawaited(_process(notePath));
    });
  }

  /// Exports every note that is still waiting, e.g. after a restart
  /// or after being offline.
  static Future<void> flushPending() async {
    if (!isActive) return;
    final pending = stows.gdrivePdfPending.value
        .where((path) => !_timers.containsKey(path))
        .toList(growable: false);
    for (final notePath in pending) {
      await _process(notePath);
    }
  }

  /// Re-exports every note, e.g. after turning the feature on.
  static Future<void> exportAll() async {
    if (!isActive) return;
    final notes = await FileManager.getAllFiles();
    stows.gdrivePdfPending.value.addAll(
      notes.where((path) => !Editor.isReservedPath(path)),
    );
    stows.gdrivePdfPending.notifyListeners();
    await flushPending();
  }

  static Future<void> _process(String notePath) => _lock.protect(() async {
    if (!isActive) return;
    try {
      final noteExists =
          FileManager.getFile(notePath + Editor.extension).existsSync() ||
          FileManager.getFile(notePath + Editor.extensionOldJson).existsSync();
      if (noteExists) {
        await _export(notePath);
      } else {
        await DriveTree.trashFile(DriveRoot.pdf, '$notePath.pdf');
      }
      stows.gdrivePdfPending.value.remove(notePath);
      stows.gdrivePdfPending.notifyListeners();
    } catch (e, st) {
      // Stays in the pending set and is retried on the next sync.
      log.warning('PDF export failed for $notePath: $e', e, st);
    }
  });

  static Future<void> _export(String notePath) async {
    final coreInfo = await EditorCoreInfo.loadFromFilePath(notePath);
    if (coreInfo.pages.isEmpty) return;

    final bytes = await EditorExporter.generatePdfBytes(coreInfo);

    await DriveTree.uploadFile(
      DriveRoot.pdf,
      '$notePath.pdf',
      bytes,
      modifiedTime: DateTime.now(),
      mimeType: 'application/pdf',
    );
    log.info('Exported $notePath.pdf to Drive');
  }
}
