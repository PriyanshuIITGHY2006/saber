import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/prefs.dart';

/// Thrown when a Drive request is made but the user isn't signed in,
/// or the Drive permission was revoked.
class DriveNotSignedInException implements Exception {
  const DriveNotSignedInException();

  @override
  String toString() => 'DriveNotSignedInException';
}

/// Google sign-in for the Google Drive sync backend.
///
/// Only the `drive.file` scope is requested, so the app can only see
/// files and folders it created itself (or that the user opened with it).
abstract final class DriveAuth {
  static final log = Logger('DriveAuth');

  static const scopes = <String>['https://www.googleapis.com/auth/drive.file'];

  /// The client ID of the *Web* OAuth client in Google Cloud.
  /// Pass it at build time with
  /// `--dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com`.
  static const serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  /// Only Android is set up for now. iOS would also need an iOS OAuth
  /// client and `GIDClientID` in `ios/Runner/Info.plist`.
  static bool get isSupported => Platform.isAndroid;

  static Future<void>? _initFuture;
  static Future<void> _ensureInitialized() {
    return _initFuture ??= GoogleSignIn.instance.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
  }

  /// Interactive sign-in. Must be called from a user action.
  /// Returns the signed-in email address.
  static Future<String> signIn() async {
    await _ensureInitialized();
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: scopes,
    );
    await account.authorizationClient.authorizeScopes(scopes);
    stows.gdriveEmail.value = account.email;
    stows.gdriveEnabled.value = true;
    log.info('Signed in to Google Drive as ${account.email}');
    return account.email;
  }

  /// Signs out and revokes the Drive permission.
  /// Local notes and files already on Drive are left untouched.
  static Future<void> signOut() async {
    stows.gdriveEnabled.value = false;
    stows.gdriveEmail.value = '';
    stows.gdriveSyncFolderId.value = '';
    stows.gdrivePdfFolderId.value = '';
    try {
      await _ensureInitialized();
      await GoogleSignIn.instance.disconnect();
    } catch (e, st) {
      log.warning('Failed to disconnect Google account: $e', e, st);
    }
  }

  /// Returns HTTP headers with a valid access token,
  /// or null if the user would need to sign in again.
  ///
  /// Access tokens expire after about an hour, so call this
  /// before every request instead of caching the result.
  static Future<Map<String, String>?> headers() async {
    if (!stows.gdriveEnabled.value) return null;
    await _ensureInitialized();

    try {
      final headers = await GoogleSignIn.instance.authorizationClient
          .authorizationHeaders(scopes);
      if (headers != null) return headers;
    } catch (e, st) {
      log.fine('Silent authorization failed: $e', e, st);
    }

    try {
      final account = await GoogleSignIn.instance
          .attemptLightweightAuthentication();
      if (account == null) return null;
      return await account.authorizationClient.authorizationHeaders(scopes);
    } catch (e, st) {
      log.warning('Lightweight authentication failed: $e', e, st);
      return null;
    }
  }

  /// Drops a token that the server rejected so the next call
  /// to [headers] fetches a fresh one.
  static Future<void> invalidate(Map<String, String> headers) async {
    final authorization = headers['Authorization'];
    if (authorization == null) return;
    final token = authorization.replaceFirst('Bearer ', '');
    try {
      await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(
        accessToken: token,
      );
    } catch (e, st) {
      log.fine('Failed to clear access token: $e', e, st);
    }
  }
}
