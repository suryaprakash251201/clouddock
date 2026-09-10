# CloudDock — S3 File Browser for iOS + Android

[![CI](https://github.com/suryaprakash251201/clouddock/actions/workflows/ci.yml/badge.svg)](https://github.com/suryaprakash251201/clouddock/actions/workflows/ci.yml)
[![Android](https://github.com/suryaprakash251201/clouddock/actions/workflows/android.yml/badge.svg)](https://github.com/suryaprakash251201/clouddock/actions/workflows/android.yml)
[![iOS](https://github.com/suryaprakash251201/clouddock/actions/workflows/ios.yml/badge.svg)](https://github.com/suryaprakash251201/clouddock/actions/workflows/ios.yml)
[![Security](https://github.com/suryaprakash251201/clouddock/actions/workflows/security.yml/badge.svg)](https://github.com/suryaprakash251201/clouddock/actions/workflows/security.yml)

Single Flutter codebase for browsing **AWS S3, Cloudflare R2, MinIO, Wasabi,
Backblaze B2, and any S3-compatible server** via one generic SigV4 client.

## Download

Grab the latest signed builds from
[GitHub Releases](https://github.com/suryaprakash251201/clouddock/releases):

- **Android:** `app-release.apk` (direct install) and `app-release.aab`
  (Play Store upload) — built by the `Android` workflow on every `v*` tag.
- **iOS:** unsigned `clouddock-ios-unsigned.ipa` for CI verification
  (re-sign to install; stock devices reject unsigned IPAs).
  Store/TestFlight distribution requires Apple signing (see below).

## Features (v1.0)

- **Accounts**: presets for AWS / R2 / Wasabi / B2 / MinIO / Custom,
  path-style toggle, SSL toggle, connection test (`ListBuckets`), secrets in
  Keychain/Keystore (never in prefs/logs).
- **Buckets**: list, create (with `LocationConstraint`), delete, refresh.
- **Browser**: folder nav + breadcrumbs, prefix-delimiter listing, local
  filter, new folder, upload (single PUT ≤ 8 MB, multipart above), download
  with progress, rename (copy+delete), delete, 1-hour presigned share links,
  object details sheet.
- **In-app viewers** (tap a file to open):
  - Images (zoomable) — jpg/png/gif/webp/bmp/heic
  - Text editor (edit + save back to S3, 2 MB edit cap) — txt/md/json/xml/csv/log/yaml/code
  - PDF viewer (PDFium, text selection) — pdf
  - Video player (presigned-URL streaming + fullscreen) — mp4/mov/webm/mkv
  - Audio player (presigned-URL streaming) — mp3/m4a/aac/wav/flac/ogg/opus
- **Object details**: full HEAD metadata (content type, ETag, storage class,
  version id, cache headers), custom `x-amz-meta-*`, editable object tags,
  key-path copy, and one-tap favorite/star.
- **Version history**: list versions + delete markers, restore an old version,
  download/share a specific version, and permanently delete versions.
- **Upload links**: create a presigned PUT URL so anyone can upload into the
  current folder until it expires (15 min / 1 h / 24 h).
- **Uploads**: device files, photo library multi-select, and camera capture.
- **Starred**: pin files from details/selection; Home shows them for quick
  access (persisted on-device).
- **Multi-select**: batch download, star, and delete selected objects.
- **Transfers**: foreground queue with progress, cancel, clear-finished,
  open-downloaded-file, per-version downloads.
- **Settings**: appearance, browsing defaults, storage tools, app lock,
  diagnostics, and provider tips.
- **Shell**: floating rounded glass bottom navigation with transfer-count
  badges, auto-hiding when a screen takes over the bottom area
  (multi-select mode).

## Project layout

```
lib/
  main.dart
  src/
    app.dart                    # MaterialApp + go_router (tabs + viewers)
    core/
      app_info.dart             # displayed app version
      s3/
        s3_account.dart         # S3Account model + ProviderType + presets
        s3_models.dart          # Bucket/Object/Details/Version/Tag models
        s3_exceptions.dart      # Typed errors with actionable messages
        sigv4.dart              # SigV4 header + presign GET/PUT (all providers)
        s3_client.dart          # ListObjects/Versions, CRUD, tags, presign, multipart
      storage/account_store.dart  # SharedPrefs metadata + SecureStorage secrets
      prefs/app_prefs.dart        # theme, view mode, link expiry, app lock
      utils/format.dart           # byte formatting
    features/
      accounts/  buckets/  browser/   # browser + details + versions screens
      favorites/                      # starred files store
      home/  transfers/  settings/  viewers/
    ui/                           # glass widgets, floating nav, theme, visuals
test/
  sigv4_test.dart               # AWS vectors + presign consistency
  s3_client_test.dart           # URI building + XML parsing (mock http)
  s3_features_test.dart         # details/tags/versions/presign tests
  s3_stability_test.dart        # retries, error mapping, atomic IO
  favorites_store_test.dart     # starred persistence + pruning
  viewer_kind_test.dart         # extension → viewer mapping
  widget_test.dart              # App boot smoke test
.github/workflows/
  ci.yml                        # analyze + format + test
  android.yml                   # release APK + AAB, attaches to v* releases
  ios.yml                   # unsigned release IPA (macos runner)
  security.yml                  # dependency-review + Gitleaks + OSV + Trivy
```

## Provider setup

| Provider | Endpoint example | Region | Path-style |
|---|---|---|---|
| AWS S3 | `s3.us-east-1.amazonaws.com` | bucket region | off |
| Cloudflare R2 | `<acct>.r2.cloudflarestorage.com` | `auto` | **on** |
| Wasabi | `s3.eu-west-1.wasabisys.com` | bucket region | off |
| Backblaze B2 | `s3.us-west-002.backblazeb2.com` | bucket region | off |
| MinIO | `192.168.1.10:9000` | `us-east-1` | **on**, SSL off for HTTP dev |
| Custom | `s3.example.com` | server region | toggle if listing fails |

If listing fails with `AuthorizationHeaderMalformed` → wrong region/endpoint.
If it fails with `AccessDenied` → key scope or bucket policy.

## Develop

```bash
flutter pub get
flutter analyze
flutter test
flutter run            # device / simulator
```

`flutter analyze` is clean (info lints only); `flutter test` → 71/71 pass
(SigV4 verified against Python `hmac` ground truth; version/tag/presign
parsing covered with a mock HTTP client; floating nav geometry covered by
widget tests).

## Device builds

- Android: `flutter build apk --release` / `flutter build appbundle`
  (permissions + cleartext for LAN MinIO already in
  `AndroidManifest.xml`). CI does this automatically.
- iOS: `flutter build ipa` in Xcode with a paid team (usage descriptions +
  Files integration already in `Info.plist`). CI builds unsigned for
  verification; attach your `IOS_DIST_CERT_P12`, provisioning profile, and
  `EXPORT_OPTIONS_PLIST` secrets to cut signed TestFlight builds.

## Security

See [SECURITY.md](SECURITY.md) for the reporting policy and data-handling
notes. The weekly `Security` workflow runs dependency-review, Gitleaks
secret scanning, OSV, and Trivy filesystem scans; Dependabot tracks
`pub` + GitHub Actions updates.

## Roadmap (V2)

- Background uploads/downloads (WorkManager / BGTasks), resume.
- ACL/encryption editors, STS/SSO, offline sync.
- Lifecycle rules, bucket policies, cross-bucket copy/move.
- **Done since v1.0:** object details + tags, version history
  (list/restore/delete), presigned upload links, starred files,
  multi-select batch actions, photo/camera uploads, pagination/load-more.
