import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/gdrive/drive_api.dart';
import 'package:saber/data/gdrive/drive_syncer.dart';
import 'package:saber/data/nextcloud/saber_syncer.dart' show BestFile;

import 'utils/test_mock_channel_handlers.dart';

DriveItem _item({
  String id = 'id1',
  DateTime? modifiedTime,
  Map<String, String> appProperties = const {},
}) => DriveItem(
  id: id,
  name: 'note.sbn2',
  mimeType: 'application/octet-stream',
  parents: const ['root'],
  modifiedTime: modifiedTime,
  size: 10,
  appProperties: appProperties,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupMockPathProvider();
  FlavorConfig.setup();

  setUpAll(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
  });

  group('DriveItem', () {
    test('parses a Drive API response', () {
      final item = DriveItem.fromJson({
        'id': 'abc',
        'name': 'Week 1.sbn2',
        'mimeType': 'application/octet-stream',
        'parents': ['folder'],
        'modifiedTime': '2026-11-18T10:00:00.123Z',
        'size': '2048',
        'appProperties': {DriveApi.deletedKey: 'false'},
      });
      expect(item.id, 'abc');
      expect(item.name, 'Week 1.sbn2');
      expect(item.parents, ['folder']);
      expect(item.size, 2048);
      expect(item.modifiedTime, DateTime.utc(2026, 11, 18, 10, 0, 0, 123));
      expect(item.isFolder, isFalse);
      expect(item.isDeletedMarker, isFalse);
    });

    test('recognises folders and deleted markers', () {
      final folder = DriveItem.fromJson({
        'id': 'f',
        'name': 'Maths',
        'mimeType': DriveApi.folderMimeType,
      });
      expect(folder.isFolder, isTrue);
      expect(folder.size, 0);
      expect(folder.parents, isEmpty);

      final deleted = _item(appProperties: {DriveApi.deletedKey: 'true'});
      expect(deleted.isDeletedMarker, isTrue);
    });
  });

  group('DriveSyncInterface.getBestFile', () {
    const relativePath = '/gdrive_test/note.sbn2';
    late File localFile;
    final localTime = DateTime.utc(2026, 11, 18, 12);

    setUp(() async {
      localFile = FileManager.getFile(relativePath);
      await localFile.create(recursive: true);
      await localFile.writeAsString('local');
      await localFile.setLastModified(localTime);
    });

    tearDown(() async {
      if (localFile.existsSync()) await localFile.delete();
    });

    BestFile best(DriveItem? remote) => DriveSyncInterface.getBestFile(
      DriveSyncFile(localFile: localFile, remoteFile: remote),
      onLocalFileNotFound: BestFile.remote,
      onEqualFiles: BestFile.local,
    );

    test('relative path matches the notes folder layout', () {
      final syncFile = DriveSyncFile(localFile: localFile, remoteFile: null);
      expect(syncFile.relativePath, relativePath);
    });

    test('keeps local when Drive has no copy', () {
      expect(best(null), BestFile.local);
    });

    test('keeps the newer side', () {
      expect(
        best(_item(modifiedTime: localTime.add(const Duration(minutes: 1)))),
        BestFile.remote,
      );
      expect(
        best(
          _item(modifiedTime: localTime.subtract(const Duration(minutes: 1))),
        ),
        BestFile.local,
      );
    });

    test('treats timestamps within 500ms as equal', () {
      expect(
        best(
          _item(
            modifiedTime: localTime.add(const Duration(milliseconds: 300)),
          ),
        ),
        BestFile.local,
      );
    });

    test('uses onLocalFileNotFound when the local file is missing', () async {
      await localFile.delete();
      expect(best(_item(modifiedTime: localTime)), BestFile.remote);
    });
  });

  test('local changes are ignored while Drive sync is off', () {
    expect(DriveSync.isActive, isFalse);
    // Should not throw or queue anything.
    DriveSync.onLocalChange('/gdrive_test/other.sbn2');
    expect(driveSyncer.uploader.numPending, 0);
  });
}
