import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/components/settings/settings_subtitle.dart';
import 'package:saber/components/settings/settings_switch.dart';
import 'package:saber/data/gdrive/drive_auth.dart';
import 'package:saber/data/gdrive/drive_pdf_exporter.dart';
import 'package:saber/data/gdrive/drive_syncer.dart';
import 'package:saber/data/prefs.dart';

/// Settings section for the Google Drive sync backend.
class GoogleDriveSettings extends StatefulWidget {
  const GoogleDriveSettings({super.key});

  @override
  State<GoogleDriveSettings> createState() => _GoogleDriveSettingsState();
}

class _GoogleDriveSettingsState extends State<GoogleDriveSettings> {
  var _busy = false;
  final _subscriptions = <StreamSubscription<void>>[];

  @override
  void initState() {
    super.initState();
    stows.gdriveEnabled.addListener(_refresh);
    stows.gdriveEmail.addListener(_refresh);
    stows.gdrivePdfPending.addListener(_refresh);
    _subscriptions
      ..add(driveSyncer.uploader.queueStream.listen((_) => _refresh()))
      ..add(driveSyncer.downloader.queueStream.listen((_) => _refresh()));
  }

  @override
  void dispose() {
    stows.gdriveEnabled.removeListener(_refresh);
    stows.gdriveEmail.removeListener(_refresh);
    stows.gdrivePdfPending.removeListener(_refresh);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    try {
      final email = await DriveAuth.signIn();
      _showMessage('Connected to Google Drive as $email');
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      _showMessage('Google sign-in failed: ${e.description ?? e.code.name}');
    } catch (e) {
      _showMessage('Google sign-in failed: $e');
    }
  });

  Future<void> _disconnect() => _run(() async {
    await DriveAuth.signOut();
    _showMessage('Disconnected. Your notes on Drive were not deleted.');
  });

  Future<void> _syncNow() => _run(() async {
    await DriveSync.syncNow();
    _showMessage('Checked Google Drive for changes');
  });

  Future<void> _exportAll() => _run(() async {
    await DrivePdfExporter.exportAll();
    final failed = stows.gdrivePdfPending.value.length;
    _showMessage(
      failed == 0
          ? 'All notes exported as PDF'
          : 'Exported, but $failed notes will be retried later',
    );
  });

  @override
  Widget build(BuildContext context) {
    if (!DriveAuth.isSupported) return const SizedBox.shrink();

    final connected = stows.gdriveEnabled.value;
    final uploads = driveSyncer.uploader.numPending;
    final downloads = driveSyncer.downloader.numPending;
    final pdfs = stows.gdrivePdfPending.value.length;

    final status = <String>[
      if (uploads > 0) '$uploads to upload',
      if (downloads > 0) '$downloads to download',
      if (pdfs > 0 && stows.gdriveExportPdfs.value) '$pdfs PDFs to update',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsSubtitle(subtitle: 'Google Drive'),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          leading: const Icon(Icons.add_to_drive),
          title: Text(connected ? stows.gdriveEmail.value : 'Google Drive sync'),
          subtitle: Text(
            connected
                ? (status.isEmpty ? 'Up to date' : status.join(' · '))
                : 'Sync your notes to a "Saber" folder in your Drive',
          ),
          trailing: _busy
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : connected
              ? TextButton(
                  onPressed: _disconnect,
                  child: const Text('Disconnect'),
                )
              : FilledButton(
                  onPressed: _connect,
                  child: const Text('Connect'),
                ),
        ),
        if (connected) ...[
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
            leading: const Icon(Icons.sync),
            title: const Text('Sync now'),
            onTap: _busy ? null : _syncNow,
          ),
          SettingsSwitch(
            title: 'Save a PDF of each note',
            subtitle:
                'Keeps a PDF copy of every note in "Saber Notes (PDF)" '
                'on Drive, updated shortly after you stop writing',
            icon: Icons.picture_as_pdf,
            pref: stows.gdriveExportPdfs,
            afterChange: (enabled) {
              if (enabled) unawaited(DrivePdfExporter.flushPending());
            },
          ),
          if (stows.gdriveExportPdfs.value)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
              leading: const Icon(Icons.library_books),
              title: const Text('Export all notes as PDF'),
              subtitle: const Text('Use this once after connecting'),
              onTap: _busy ? null : _exportAll,
            ),
        ],
      ],
    );
  }
}
