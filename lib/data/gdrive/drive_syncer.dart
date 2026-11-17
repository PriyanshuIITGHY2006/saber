import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:abstract_sync/abstract_sync.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/gdrive/drive_api.dart';
import 'package:saber/data/gdrive/drive_auth.dart';
import 'package:saber/data/gdrive/drive_pdf_exporter.dart';
import 'package:saber/data/gdrive/drive_tree.dart';
import 'package:saber/data/nextcloud/nextcloud_client_extension.dart';
import 'package:saber/data/nextcloud/saber_syncer.dart' show BestFile;
import 'package:saber/data/prefs.dart';

/// Syncs the local notes folder with a `Saber` folder on Google Drive.
///
/// Unlike the Nextcloud syncer, files are stored unencrypted with their
/// real names, so they can be read by other tools (like a website).
final driveSyncer = Syncer<DriveSyncInterface, DriveSyncFile, File, DriveItem>(
  const DriveSyncInterface(),
  failureTimeout: const Duration(seconds: 4),
);

/// Entry points used by the rest of the app.
abstract final class DriveSync {
  static final log = Logger('DriveSync');

  static bool get isActive => DriveAuth.isSupported && stows.gdriveEnabled.value;

  static bool _started = false;

  /// Files edited again while their previous upload was still queued.
  static final _changedWhilePending = <String>{};
  static StreamSubscription<DriveSyncFile>? _transferSubscription;
  static AppLifecycleListener? _lifecycleListener;
  static Timer? _periodicSync;

  /// How often to check Drive for changes while the app is open.
  static const syncInterval = Duration(minutes: 5);

  /// Starts syncing once prefs have loaded, and again whenever
  /// Drive sync gets switched on.
  static Future<void> start() async {
    if (!DriveAuth.isSupported) return;
    await Future.wait([
      stows.gdriveEnabled.waitUntilRead(),
      stows.gdriveEmail.waitUntilRead(),
      stows.gdriveSyncFolderId.waitUntilRead(),
      stows.gdrivePdfFolderId.waitUntilRead(),
      stows.gdriveExportPdfs.waitUntilRead(),
      stows.gdrivePdfPending.waitUntilRead(),
    ]);
    if (!_started) {
      _started = true;
      stows.gdriveEnabled.addListener(_onEnabledChanged);
      _transferSubscription = driveSyncer.uploader.transferStream.listen(
        _onUploaded,
      );
      _lifecycleListener = AppLifecycleListener(
        onResume: () {
          unawaited(syncNow());
          _startPeriodicSync();
        },
        onPause: () => _periodicSync?.cancel(),
      );
      _startPeriodicSync();
    }
    if (isActive) await syncNow();
  }

  static void _onEnabledChanged() {
    if (isActive) {
      unawaited(syncNow());
    } else {
      driveSyncer.uploader
        ..dispose()
        ..clearPending();
      driveSyncer.downloader
        ..dispose()
        ..clearPending();
      DriveTree.reset();
    }
  }

  /// Checks both sides for changes and queues the transfers.
  static Future<void> syncNow() async {
    if (!isActive) return;
    await driveSyncer.downloader.refresh();
    await driveSyncer.uploader.refresh();
    unawaited(DrivePdfExporter.flushPending());
  }

  /// Called by [FileManager] whenever the user creates, edits, moves
  /// or deletes a file, with the file's path relative to the notes folder.
  static void onLocalChange(String relativePath) {
    if (!isActive) return;
    final localFile = FileManager.getFile(relativePath);
    if (driveSyncer.uploader.isLocalFilePending(localFile)) {
      // The queued upload may already have read the old contents,
      // so upload again once it finishes.
      _changedWhilePending.add(relativePath);
    } else {
      unawaited(driveSyncer.uploader.enqueue(localFile: localFile));
    }
    DrivePdfExporter.onLocalChange(relativePath);
  }

  static void _startPeriodicSync() {
    _periodicSync?.cancel();
    _periodicSync = Timer.periodic(syncInterval, (_) {
      if (isActive && !driveSyncer.downloader.isRefreshing) {
        unawaited(syncNow());
      }
    });
  }

  static void _onUploaded(DriveSyncFile file) {
    if (!_changedWhilePending.remove(file.relativePath)) return;
    unawaited(driveSyncer.uploader.enqueue(localFile: file.localFile));
  }

  /// Stops listening for uploads. Only used in tests.
  static Future<void> dispose() async {
    await _transferSubscription?.cancel();
    _transferSubscription = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _periodicSync?.cancel();
    _periodicSync = null;
    _started = false;
  }
}

class DriveSyncInterface
    extends AbstractSyncInterface<DriveSyncFile, File, DriveItem> {
  const DriveSyncInterface();

  static final log = Logger('DriveSyncInterface');

  /// Local files that should never be uploaded.
  static bool _isIgnored(String relativePath) {
    final name = relativePath.substring(relativePath.lastIndexOf('/') + 1);
    return name.startsWith('.') ||
        relativePath == '/${NextcloudClientExtension.configFileName}';
  }

  @override
  bool areRemoteFilesEqual(DriveItem a, DriveItem b) => a.id == b.id;

  @override
  bool areLocalFilesEqual(File a, File b) => a.path == b.path;

  @override
  Future<DriveSyncFile> getSyncFileFromLocalFile(File localFile) async {
    final relativePath = DriveSyncFile.relativePathOf(localFile);
    return DriveSyncFile(
      localFile: localFile,
      remoteFile: DriveTree.syncFiles[relativePath],
    );
  }

  @override
  Future<DriveSyncFile> getSyncFileFromRemoteFile(DriveItem remoteFile) async {
    final relativePath = DriveTree.syncPathOf(remoteFile.id);
    if (relativePath == null) {
      throw StateError('Remote file is not in the Saber folder: $remoteFile');
    }
    return DriveSyncFile(
      localFile: FileManager.getFile(relativePath),
      remoteFile: remoteFile,
    );
  }

  @override
  Future<List<DriveSyncFile>> findRemoteChanges() async {
    if (!DriveSync.isActive) return const [];

    final Map<String, DriveItem> remoteFiles;
    try {
      remoteFiles = await DriveTree.index();
    } catch (e, st) {
      log.warning('Failed to list Drive files: $e', e, st);
      return const [];
    }

    final changed = <DriveSyncFile>[];
    for (final MapEntry(key: relativePath, value: remoteFile)
        in remoteFiles.entries) {
      if (_isIgnored(relativePath)) continue;
      final localFile = FileManager.getFile(relativePath);
      final syncFile = DriveSyncFile(
        localFile: localFile,
        remoteFile: remoteFile,
      );
      final best = getBestFile(
        syncFile,
        onLocalFileNotFound: BestFile.remote,
        onEqualFiles: BestFile.local,
      );
      if (best != BestFile.remote) continue;
      // Deleted on Drive and already gone here: nothing to do.
      if (remoteFile.isDeletedMarker && !localFile.existsSync()) continue;
      changed.add(syncFile);
    }

    // Download previews (`note.sbn2.p`) before their notes,
    // so the home screen thumbnails update first.
    int priority(DriveSyncFile file) => file.relativePath.endsWith('.p') ? 0 : 1;
    changed.sort((a, b) => priority(a).compareTo(priority(b)));

    return changed;
  }

  @override
  Future<List<DriveSyncFile>> findLocalChanges() async {
    if (!DriveSync.isActive) return const [];
    if (!DriveTree.isIndexed) {
      try {
        await DriveTree.index();
      } catch (e, st) {
        log.warning('Failed to list Drive files: $e', e, st);
        return const [];
      }
    }

    final root = FileManager.getRootDirectory();
    if (!root.existsSync()) return const [];

    final changed = <DriveSyncFile>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final syncFile = await getSyncFileFromLocalFile(entity);
      if (_isIgnored(syncFile.relativePath)) continue;
      final best = getBestFile(
        syncFile,
        onLocalFileNotFound: BestFile.local,
        onEqualFiles: BestFile.remote,
      );
      if (best == BestFile.local) changed.add(syncFile);
    }
    return changed;
  }

  /// Decides whether the local or the Drive copy is the one to keep,
  /// using the same rules as the Nextcloud syncer.
  static BestFile getBestFile(
    DriveSyncFile file, {
    required BestFile onLocalFileNotFound,
    required BestFile onEqualFiles,
  }) {
    if (!file.localFile.existsSync()) return onLocalFileNotFound;

    final remoteModified = file.remoteFile?.modifiedTime;
    if (remoteModified == null) return BestFile.local;

    final localModified = file.localFile.lastModifiedSync();
    if (remoteModified.difference(localModified).abs() <
        const Duration(milliseconds: 500)) {
      return onEqualFiles;
    } else if (remoteModified.isAfter(localModified)) {
      return BestFile.remote;
    } else {
      return BestFile.local;
    }
  }

  @override
  Future<Uint8List> readLocalFile(DriveSyncFile file) async {
    if (!file.localFile.existsSync()) return Uint8List(0);
    // Note the timestamp before reading: if the file is written again
    // mid-upload, it will look newer than Drive and be uploaded again.
    try {
      file.readModifiedTime = file.localFile.lastModifiedSync();
    } on FileSystemException {
      file.readModifiedTime = null;
    }
    return file.localFile.readAsBytes();
  }

  @override
  Future<void> uploadRemoteFile(DriveSyncFile file, Uint8List bytes) async {
    if (!DriveSync.isActive) throw const DriveNotSignedInException();
    final relativePath = file.relativePath;

    if (!file.localFile.existsSync()) {
      // Deleted locally: leave an empty marker on Drive so other
      // devices delete their copy too.
      final existing = DriveTree.syncFiles[relativePath] ?? file.remoteFile;
      if (existing == null || existing.isDeletedMarker) return;
      file.remoteFile = await DriveTree.uploadFile(
        DriveRoot.sync,
        relativePath,
        Uint8List(0),
        modifiedTime: DateTime.now(),
        appProperties: const {DriveApi.deletedKey: 'true'},
      );
      return;
    }

    final lastModified = file.readModifiedTime ?? DateTime.now();

    file.remoteFile = await DriveTree.uploadFile(
      DriveRoot.sync,
      relativePath,
      bytes,
      modifiedTime: lastModified,
      appProperties: const {DriveApi.deletedKey: 'false'},
    );
  }

  @override
  Future<Uint8List> downloadRemoteFile(DriveSyncFile file) async {
    final remoteFile = file.remoteFile;
    if (remoteFile == null || remoteFile.isDeletedMarker) return Uint8List(0);
    if (!DriveSync.isActive) throw const DriveNotSignedInException();
    return DriveApi.download(remoteFile.id);
  }

  @override
  Future<void> writeLocalFile(DriveSyncFile file, Uint8List bytes) async {
    final remoteFile = file.remoteFile;
    if (remoteFile == null) return;

    if (remoteFile.isDeletedMarker) {
      if (file.localFile.existsSync()) {
        await FileManager.deleteFile(file.relativePath, alsoUpload: false);
      }
      return;
    }

    await FileManager.writeFile(
      file.relativePath,
      bytes,
      awaitWrite: true,
      alsoUpload: false,
      // Keep the same timestamp locally and on Drive,
      // so the file isn't uploaded straight back.
      lastModified: remoteFile.modifiedTime,
    );
  }
}

class DriveSyncFile extends AbstractSyncFile<File, DriveItem> {
  DriveSyncFile({required super.localFile, required super.remoteFile});

  /// The path relative to the notes folder, e.g. `/Maths/Week 1.sbn2`.
  late final String relativePath = relativePathOf(localFile);

  /// The local file's last modified time when it was read for upload.
  DateTime? readModifiedTime;

  static String relativePathOf(File localFile) => localFile.path
      .substring(FileManager.documentsDirectory.length)
      .replaceAll(Platform.pathSeparator, '/');

  @override
  String toString() => 'DriveSyncFile($relativePath)';

  @override
  bool operator ==(Object other) =>
      other is DriveSyncFile && other.localFile.path == localFile.path;

  @override
  int get hashCode => localFile.path.hashCode;
}
