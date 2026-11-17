import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:mutex/mutex.dart';
import 'package:saber/data/gdrive/drive_api.dart';
import 'package:saber/data/prefs.dart';
import 'package:stow_plain/stow_plain.dart';

/// Which of the app's two top-level Drive folders a file lives in.
enum DriveRoot {
  /// Raw Saber files (`.sbn2` notes and their assets), mirrored 1:1.
  sync('sync', 'Saber'),

  /// Read-only PDF copies of each note, for the website.
  pdf('pdf', 'Saber Notes (PDF)');

  const DriveRoot(this.role, this.defaultFolderName);

  final String role;
  final String defaultFolderName;

  PlainStow<String> get _idStow => switch (this) {
    DriveRoot.sync => stows.gdriveSyncFolderId,
    DriveRoot.pdf => stows.gdrivePdfFolderId,
  };
}

/// Keeps track of the folder structure of the app's files on Drive,
/// so that a local path like `/Maths/Week 1.sbn2` maps to
/// `Saber/Maths/Week 1.sbn2` on Drive.
///
/// The two root folders are found by ID (and a private role property),
/// not by name, so they can be renamed or moved anywhere in Drive
/// (e.g. into the website's `files` folder) without breaking sync.
abstract final class DriveTree {
  static final log = Logger('DriveTree');
  static final _lock = Mutex();

  static final _rootIds = <DriveRoot, String>{};
  static final _folders = {
    for (final root in DriveRoot.values) root: <String, String>{},
  };
  static final _files = {
    for (final root in DriveRoot.values) root: <String, DriveItem>{},
  };
  static final _syncPathById = <String, String>{};

  static bool _indexed = false;
  static bool get isIndexed => _indexed;

  /// Remote sync files by relative path, e.g. `/Maths/Week 1.sbn2`.
  static Map<String, DriveItem> get syncFiles => _files[DriveRoot.sync]!;

  static String? syncPathOf(String fileId) => _syncPathById[fileId];

  /// Forgets everything, e.g. after signing out.
  static void reset() {
    _rootIds.clear();
    for (final map in _folders.values) map.clear();
    for (final map in _files.values) map.clear();
    _syncPathById.clear();
    _indexed = false;
  }

  /// Lists every file the app can see on Drive and rebuilds the index.
  /// Returns [syncFiles].
  static Future<Map<String, DriveItem>> index() => _lock.protect(() async {
    final rootIds = {
      for (final root in DriveRoot.values) root: await _rootId(root),
    };
    final items = await DriveApi.listAll();
    final byId = {for (final item in items) item.id: item};

    String? pathRelativeTo(DriveItem item, String rootId) {
      final segments = <String>[];
      var current = item;
      for (var depth = 0; depth < 64; depth++) {
        if (current.parents.isEmpty) return null;
        segments.add(current.name);
        final parentId = current.parents.first;
        if (parentId == rootId) return '/${segments.reversed.join('/')}';
        final parent = byId[parentId];
        if (parent == null) return null;
        current = parent;
      }
      return null;
    }

    for (final root in DriveRoot.values) {
      _folders[root]!
        ..clear()
        ..[''] = rootIds[root]!;
      _files[root]!.clear();
    }
    _syncPathById.clear();

    for (final item in items) {
      for (final root in DriveRoot.values) {
        final rootId = rootIds[root]!;
        if (item.id == rootId) continue;
        final path = pathRelativeTo(item, rootId);
        if (path == null) continue;

        if (item.isFolder) {
          _folders[root]![path] = item.id;
        } else {
          final existing = _files[root]![path];
          // Drive allows duplicate names; keep the newest copy.
          if (existing == null || _isNewer(item, existing)) {
            _files[root]![path] = item;
            if (root == DriveRoot.sync) _syncPathById[item.id] = path;
          }
        }
        break;
      }
    }

    _indexed = true;
    log.info(
      'Indexed ${syncFiles.length} synced files and '
      '${_files[DriveRoot.pdf]!.length} PDFs',
    );
    return Map.of(syncFiles);
  });

  static bool _isNewer(DriveItem a, DriveItem b) {
    final aTime = a.modifiedTime, bTime = b.modifiedTime;
    if (aTime == null) return false;
    if (bTime == null) return true;
    return aTime.isAfter(bTime);
  }

  /// Returns the ID of [root], finding or creating it if needed.
  /// Call only while holding [_lock].
  static Future<String> _rootId(DriveRoot root) async {
    final cached = _rootIds[root];
    if (cached != null) return cached;

    final stow = root._idStow;
    var folder = await DriveApi.getItem(stow.value);
    folder ??= await DriveApi.findFolderWithRole(root.role);
    folder ??= await DriveApi.createFolder(
      root.defaultFolderName,
      appProperties: {DriveApi.roleKey: root.role},
    );

    stow.value = folder.id;
    _rootIds[root] = folder.id;
    _folders[root]![''] = folder.id;
    return folder.id;
  }

  /// Returns the ID of the folder at [dirPath] (e.g. `/Maths`) inside
  /// [root], creating any missing folders along the way.
  static Future<String> ensureFolder(DriveRoot root, String dirPath) async {
    if (!_indexed) await index();
    return _lock.protect(() async {
      final folders = _folders[root]!;
      var parentId = await _rootId(root);
      var current = '';
      for (final segment in dirPath.split('/')) {
        if (segment.isEmpty) continue;
        current = '$current/$segment';
        final known = folders[current];
        if (known != null) {
          parentId = known;
          continue;
        }
        final created = await DriveApi.createFolder(segment, parentId: parentId);
        folders[current] = created.id;
        parentId = created.id;
      }
      return parentId;
    });
  }

  static void putSyncFile(String path, DriveItem item) {
    syncFiles[path] = item;
    _syncPathById[item.id] = path;
  }

  static (String dir, String name) _split(String path) {
    final slash = path.lastIndexOf('/');
    return (path.substring(0, slash), path.substring(slash + 1));
  }

  /// Uploads [bytes] to [path] in [root], replacing any existing file.
  static Future<DriveItem> uploadFile(
    DriveRoot root,
    String path,
    Uint8List bytes, {
    required DateTime modifiedTime,
    String mimeType = 'application/octet-stream',
    Map<String, String> appProperties = const {},
  }) async {
    if (!_indexed) await index();
    final (dir, name) = _split(path);
    final existing = _files[root]![path];

    DriveItem uploaded;
    try {
      uploaded = await DriveApi.upload(
        existingId: existing?.id,
        name: name,
        parentId: existing == null ? await ensureFolder(root, dir) : null,
        bytes: bytes,
        modifiedTime: modifiedTime,
        mimeType: mimeType,
        appProperties: appProperties,
      );
    } on DriveApiException catch (e) {
      // The file or one of its folders was deleted on Drive:
      // refresh the index and try once more.
      if (e.statusCode != 404) rethrow;
      await index();
      final retryExisting = _files[root]![path];
      uploaded = await DriveApi.upload(
        existingId: retryExisting?.id,
        name: name,
        parentId: retryExisting == null ? await ensureFolder(root, dir) : null,
        bytes: bytes,
        modifiedTime: modifiedTime,
        mimeType: mimeType,
        appProperties: appProperties,
      );
    }

    _files[root]![path] = uploaded;
    if (root == DriveRoot.sync) _syncPathById[uploaded.id] = path;
    return uploaded;
  }

  /// Moves the file at [path] in [root] to the Drive bin, if it exists.
  static Future<void> trashFile(DriveRoot root, String path) async {
    if (!_indexed) await index();
    final existing = _files[root]!.remove(path);
    if (existing == null) return;
    if (root == DriveRoot.sync) _syncPathById.remove(existing.id);
    await DriveApi.trash(existing.id);
  }
}
