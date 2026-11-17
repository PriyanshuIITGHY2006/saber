# Saber Drive: Google Drive sync fork

This fork of [Saber](https://github.com/saber-notes/saber) adds a Google Drive
sync option next to the built-in Nextcloud sync, and can keep a PDF copy of
every note on Drive. It is licensed under GPL-3.0 like the original.

## What it does

- **Settings > Google Drive > Connect** signs in with Google. The app only asks
  for the `drive.file` permission, so it can only see files it created.
- Notes are mirrored to a Drive folder called **Saber**, with the same folder
  structure as in the app: `/Maths/Week 1` becomes `Saber/Maths/Week 1.sbn2`
  (plus small `.sbn2.0`, `.sbn2.p` files for images and previews).
  Files are not encrypted, so other tools can read them.
- With **Save a PDF of each note** on, every note also gets a PDF in
  **Saber Notes (PDF)**, about 20 seconds after you stop writing.
  Deleting or moving a note updates its PDF too.
- Sync runs when the app opens, when it comes back to the foreground, every
  5 minutes while open, and on **Sync now**.
- Both folders are tracked by ID, so you can rename them or move them
  anywhere in your Drive (for example into your website's `files` folder).
- When a note is deleted, an empty marker file is left in the Saber folder so
  your other devices delete it too.
- Android only for now. The app ID is
  `me.priyanshudebnath.saber`, so it installs alongside the official Saber.

## One-time setup

### 1. Push this branch to your fork

Fork `saber-notes/saber` on GitHub, then from this folder:

```bash
git remote add fork https://github.com/<your-username>/saber.git
git push fork gdrive-sync
```

### 2. Create a signing key

Google sign-in checks the SHA-1 of the key that signed the APK, so use your
own key (the repo's fallback key is public):

```bash
keytool -genkeypair -v -keystore saber-drive.jks -alias saberdrive \
  -keyalg RSA -keysize 4096 -validity 10000
keytool -list -v -keystore saber-drive.jks -alias saberdrive | grep SHA1
base64 -w0 saber-drive.jks > saber-drive.jks.b64
```

Keep `saber-drive.jks` safe and out of git. In your fork go to
**Settings > Secrets and variables > Actions** and add these secrets:

| Secret               | Value                              |
| -------------------- | ---------------------------------- |
| `SIGNING_KEY`        | contents of `saber-drive.jks.b64`  |
| `KEY_STORE_PASSWORD` | the keystore password              |
| `KEY_PASSWORD`       | the key password                   |
| `ALIAS`              | `saberdrive`                       |

### 3. Google Cloud project

1. Go to <https://console.cloud.google.com/> and create a project.
2. **APIs & Services > Library**: enable **Google Drive API**.
3. **Google Auth Platform > Branding / Audience**: set up the consent screen as
   *External*. Add yourself as a test user, or press **Publish app**: since the
   app only uses `drive.file`, which is a non-sensitive scope, it does not need
   Google's review.
4. **Data Access**: add the scope `https://www.googleapis.com/auth/drive.file`.
5. **Clients > Create client**:
   - Type **Web application**, any name. Copy its client ID.
   - Type **Android**, package name `me.priyanshudebnath.saber`, and the SHA-1
     from step 2.
6. In your fork, under **Settings > Secrets and variables > Actions >
   Variables**, add `GOOGLE_SERVER_CLIENT_ID` = the *Web* client ID.

### 4. Build

In your fork, open **Actions > Build Saber Drive (Android) > Run workflow** on
the `gdrive-sync` branch. When it finishes, download the
`Saber-Drive-Android` artifact and install the APK on your tablet.
The log of the "Print signing certificate SHA-1" step shows the SHA-1 the APK
was signed with; it must match the Android client from step 3.5.

### 5. Use it

1. Open the app, go to **Settings > Google Drive** and tap **Connect**.
2. Tap **Export all notes as PDF** once to create PDFs for existing notes.
3. In Google Drive, move **Saber Notes (PDF)** into your website's `files`
   folder. It will then show up under priyanshudebnath.me/files.

## Troubleshooting

- *Sign-in says canceled right after choosing an account*: usually a wrong
  SHA-1, package name or Web client ID. Compare the SHA-1 printed by the
  workflow with the Android client in Google Cloud.
- *"serverClientId must be provided"*: the `GOOGLE_SERVER_CLIENT_ID` variable
  was empty at build time.
- Nothing uploads: check **Settings > Google Drive** for the pending count,
  then tap **Sync now**. Failed transfers retry automatically.

## Where the code is

| File | Purpose |
| --- | --- |
| `lib/data/gdrive/drive_auth.dart` | Google sign-in and access tokens |
| `lib/data/gdrive/drive_api.dart` | Minimal Drive v3 REST client |
| `lib/data/gdrive/drive_tree.dart` | Maps note paths to Drive folders |
| `lib/data/gdrive/drive_syncer.dart` | Two-way sync on top of `abstract_sync` |
| `lib/data/gdrive/drive_pdf_exporter.dart` | Debounced PDF export per note |
| `lib/components/settings/google_drive_settings.dart` | Settings section |

Changes to upstream files are kept small: hooks in `file_manager.dart`, new
prefs in `prefs.dart`, startup in `main.dart`, the settings entry, an optional
`context` in `EditorExporter.generatePdf`, and the Android app ID and label.
To pull in a new Saber release, merge upstream into `gdrive-sync`.
