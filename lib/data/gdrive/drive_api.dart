import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:saber/data/gdrive/drive_auth.dart';

/// A file or folder on Google Drive.
class DriveItem {
  const DriveItem({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.parents,
    required this.modifiedTime,
    required this.size,
    required this.appProperties,
  });

  factory DriveItem.fromJson(Map<String, dynamic> json) {
    final modified = json['modifiedTime'] as String?;
    return DriveItem(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? '',
      parents: (json['parents'] as List?)?.cast<String>() ?? const [],
      modifiedTime: modified == null ? null : DateTime.parse(modified),
      size: int.tryParse(json['size']?.toString() ?? '') ?? 0,
      appProperties:
          (json['appProperties'] as Map?)?.cast<String, String>() ?? const {},
    );
  }

  final String id;
  final String name;
  final String mimeType;
  final List<String> parents;
  final DateTime? modifiedTime;
  final int size;

  /// Private key/value pairs only this app can see.
  final Map<String, String> appProperties;

  bool get isFolder => mimeType == DriveApi.folderMimeType;

  /// True for a tombstone left behind when a note was deleted,
  /// so other devices know to delete their copy too.
  bool get isDeletedMarker => appProperties[DriveApi.deletedKey] == 'true';

  @override
  String toString() => 'DriveItem($name, $id)';
}

class DriveApiException implements Exception {
  const DriveApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'DriveApiException($statusCode): $body';
}

/// A minimal Google Drive v3 REST client.
abstract final class DriveApi {
  static final log = Logger('DriveApi');

  static const folderMimeType = 'application/vnd.google-apps.folder';
  static const roleKey = 'saberRole';
  static const deletedKey = 'saberDeleted';

  static const _base = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';
  static const _fields =
      'id,name,mimeType,parents,modifiedTime,size,appProperties';

  /// Uploads above this size use a resumable session.
  static const _multipartLimit = 5 * 1024 * 1024;

  static final _client = http.Client();

  static Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? bodyBytes,
    bool isRetry = false,
  }) async {
    final auth = await DriveAuth.headers();
    if (auth == null) throw const DriveNotSignedInException();

    final request = http.Request(method, uri)
      ..headers.addAll(auth)
      ..headers.addAll(headers);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;

    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(minutes: 2)),
    );

    if (response.statusCode == 401 && !isRetry) {
      await DriveAuth.invalidate(auth);
      return _send(
        method,
        uri,
        headers: headers,
        bodyBytes: bodyBytes,
        isRetry: true,
      );
    }
    if (response.statusCode >= 400) {
      throw DriveApiException(response.statusCode, response.body);
    }
    return response;
  }

  static List<int> _json(Object body) => utf8.encode(jsonEncode(body));

  static const _jsonHeaders = {
    'Content-Type': 'application/json; charset=UTF-8',
  };

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse(path).replace(queryParameters: query);

  /// Lists every non-trashed file and folder this app can access.
  static Future<List<DriveItem>> listAll() async {
    final items = <DriveItem>[];
    String? pageToken;
    do {
      final response = await _send(
        'GET',
        _uri('$_base/files', {
          'q': 'trashed = false',
          'spaces': 'drive',
          'pageSize': '1000',
          'fields': 'nextPageToken,files($_fields)',
          'pageToken': ?pageToken,
        }),
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      items.addAll(
        (json['files'] as List).map(
          (e) => DriveItem.fromJson(e as Map<String, dynamic>),
        ),
      );
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);
    return items;
  }

  /// Returns the item with [id], or null if it doesn't exist,
  /// was trashed, or this app can no longer see it.
  static Future<DriveItem?> getItem(String id) async {
    if (id.isEmpty) return null;
    try {
      final response = await _send(
        'GET',
        _uri('$_base/files/$id', {'fields': '$_fields,trashed'}),
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['trashed'] == true) return null;
      return DriveItem.fromJson(json);
    } on DriveApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Finds a folder previously created by this app with the given [role].
  static Future<DriveItem?> findFolderWithRole(String role) async {
    final response = await _send(
      'GET',
      _uri('$_base/files', {
        'q':
            "mimeType = '$folderMimeType' and trashed = false and "
            "appProperties has { key='$roleKey' and value='$role' }",
        'spaces': 'drive',
        'pageSize': '10',
        'fields': 'files($_fields)',
      }),
    );
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final files = json['files'] as List;
    if (files.isEmpty) return null;
    return DriveItem.fromJson(files.first as Map<String, dynamic>);
  }

  static Future<DriveItem> createFolder(
    String name, {
    String? parentId,
    Map<String, String> appProperties = const {},
  }) async {
    final response = await _send(
      'POST',
      _uri('$_base/files', {'fields': _fields}),
      headers: _jsonHeaders,
      bodyBytes: _json({
        'name': name,
        'mimeType': folderMimeType,
        if (parentId != null) 'parents': [parentId],
        if (appProperties.isNotEmpty) 'appProperties': appProperties,
      }),
    );
    return DriveItem.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Creates a new file (if [existingId] is null) or replaces the
  /// contents of an existing one.
  static Future<DriveItem> upload({
    String? existingId,
    required String name,
    String? parentId,
    required Uint8List bytes,
    required DateTime modifiedTime,
    String mimeType = 'application/octet-stream',
    Map<String, String> appProperties = const {},
  }) async {
    assert(
      existingId != null || parentId != null,
      'A new file needs a parent folder',
    );
    final metadata = <String, Object>{
      'name': name,
      'modifiedTime': modifiedTime.toUtc().toIso8601String(),
      if (existingId == null) 'parents': [parentId!],
      if (existingId == null) 'mimeType': mimeType,
      if (appProperties.isNotEmpty) 'appProperties': appProperties,
    };
    final method = existingId == null ? 'POST' : 'PATCH';
    final path = existingId == null
        ? '$_uploadBase/files'
        : '$_uploadBase/files/$existingId';

    final http.Response response;
    if (bytes.length <= _multipartLimit) {
      const boundary = 'saber_drive_boundary_7f3a9c';
      final body = BytesBuilder(copy: false)
        ..add(
          utf8.encode(
            '--$boundary\r\n'
            'Content-Type: application/json; charset=UTF-8\r\n\r\n'
            '${jsonEncode(metadata)}\r\n'
            '--$boundary\r\n'
            'Content-Type: $mimeType\r\n\r\n',
          ),
        )
        ..add(bytes)
        ..add(utf8.encode('\r\n--$boundary--'));
      response = await _send(
        method,
        _uri(path, {'uploadType': 'multipart', 'fields': _fields}),
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
        bodyBytes: body.takeBytes(),
      );
    } else {
      final session = await _send(
        method,
        _uri(path, {'uploadType': 'resumable', 'fields': _fields}),
        headers: {
          ..._jsonHeaders,
          'X-Upload-Content-Type': mimeType,
          'X-Upload-Content-Length': '${bytes.length}',
        },
        bodyBytes: _json(metadata),
      );
      final location = session.headers['location'];
      if (location == null) {
        throw const DriveApiException(0, 'No resumable upload URL returned');
      }
      response = await _send(
        'PUT',
        Uri.parse(location),
        headers: {'Content-Type': mimeType},
        bodyBytes: bytes,
      );
    }
    return DriveItem.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Changes a file's private properties and modified time
  /// without touching its contents.
  static Future<DriveItem> updateMetadata(
    String id, {
    DateTime? modifiedTime,
    Map<String, String>? appProperties,
  }) async {
    final response = await _send(
      'PATCH',
      _uri('$_base/files/$id', {'fields': _fields}),
      headers: _jsonHeaders,
      bodyBytes: _json({
        if (modifiedTime != null)
          'modifiedTime': modifiedTime.toUtc().toIso8601String(),
        'appProperties': ?appProperties,
      }),
    );
    return DriveItem.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  static Future<Uint8List> download(String id) async {
    final response = await _send(
      'GET',
      _uri('$_base/files/$id', {'alt': 'media'}),
    );
    return response.bodyBytes;
  }

  /// Moves a file to the Drive bin (recoverable for 30 days).
  static Future<void> trash(String id) async {
    try {
      await _send(
        'PATCH',
        _uri('$_base/files/$id'),
        headers: _jsonHeaders,
        bodyBytes: _json({'trashed': true}),
      );
    } on DriveApiException catch (e) {
      if (e.statusCode == 404) return;
      rethrow;
    }
  }
}
