# Security Policy

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

Pre-1.0 development snapshots are not supported — please upgrade to the
latest `v1.x` release.

## Reporting a vulnerability

**Do not open a public issue for security reports.**

Use one of these private channels:

1. GitHub Security Advisories — **Security → Report a vulnerability**
   on this repository (preferred, keeps the thread private), or
2. Open a minimal issue with no exploit details asking for a contact,
   and we will open an advisory thread.

Include if possible:

- Affected version / commit and platform (Android / iOS).
- Provider/endpoint type (AWS, R2, MinIO, …) — no real credentials.
- Steps to reproduce and impact (what an attacker gains).
- Whether secrets, files, or other tenants are exposed.

We aim to acknowledge within **5 business days** and to ship or
mitigate confirmed high-severity issues promptly. We will credit
reporters on request once a fix is released.

## What is in scope

- The Flutter app in this repo: SigV4 signing, credential storage,
  presigned-URL sharing, transfers, deep-link / share-sheet handling.
- The GitHub Actions workflows in `.github/workflows`.
- The sample self-host guidance in `README.md` (MinIO / custom endpoints).

Out of scope: the S3 providers themselves (AWS, Cloudflare, Wasabi,
Backblaze, MinIO upstream), Apple/Google store infrastructure, and
third-party packages (report those upstream, but tell us if we need a
version bump — Dependabot + the weekly Security workflow track this).

## How CloudDock protects your data

- **Keys stay on-device.** Access/secret keys live in
  Keychain (iOS) / EncryptedSharedPreferences + Keystore (Android) via
  `flutter_secure_storage`. Only non-secret metadata is in app prefs.
  Nothing is logged, and there is no telemetry.
- **TLS by default.** HTTPS is the default; plain HTTP exists only for
  user-configured LAN/dev endpoints (e.g. MinIO) and is explicit in the
  account form.
- **Least-privilege sharing.** Share links are presigned GET URLs that
  expire after 1 hour by default (max 7 days per SigV4).
- **Fail closed.** Auth/region/endpoint mismatches surface actionable
  errors (`AuthorizationHeaderMalformed`, `AccessDenied`) instead of
  retrying with weakened auth.

## Operational guidance (self-hosters)

- Use IAM / provider tokens scoped to the buckets the device needs.
- Prefer temporary STS credentials where your provider supports them.
- Keep the app updated; watch the Security workflow and Dependabot PRs.
- Never paste real credentials into issues, logs, or screenshots.

## Disclosure policy

We follow coordinated disclosure: fixes ship first with a release note
that describes severity and upgrade steps without exploit details. If a
vulnerability is being actively exploited we may publish a short
advisory ahead of the full fix with mitigations.
