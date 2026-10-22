# Timeweb Android QA — 22 October 2026

The native meeting participant screen had lost the organizer route to removal controls. Organizers can now open those controls from the participant screen; regular participants cannot. The existing operation journal, server authorization, lost-response recovery and account-change guards remain in use. The chat lease and unsent draft close before moderation opens.

The legacy meeting chat header now scrolls within a bounded height, so long meeting titles and translation errors fit small screens and large system fonts. Approved left-aligned layouts remain in place.

Added 35 missing native UI labels across all 23 locales. Restored missing catalog generator sources and preserved all previously delivered translations. Catalog regeneration no longer requires a disposable local UI inventory. The general Dart test dependency is now explicit; UI tests use current navigation, lazy scrolling and guarded account transitions.

## Verified locally

- Full Flutter suite: 1055 passed, 1 configuration-specific skip, 0 failures (2m37s).
- That skipped startup scenario passed separately with config/timeweb.production.json: a stalled optional notification service does not block sign-in.
- Flutter analyze --no-fatal-infos: exit 0; no errors or warnings. Existing style/info diagnostics remain (272).
- Python build/signing guards: 10 passed. Catalog reproducibility guards: 2 passed.
- Targeted organizer/non-organizer, original-operation recovery, account replacement, 23-language guide and compact layout scenarios passed.
- These are local widget/unit checks with controlled fixtures. They do not establish live user load capacity, final migration reconciliation, overseas account login, SMTP delivery, store signing or publication.

## Release boundaries

Use tool/build_timeweb.py and config/timeweb.production.json for Android builds. QA APKs use the existing debug certificate and must not be uploaded as updates to the published RuStore app. Store mode requires the original signing material and its certificate fingerprint.

No external publication or Telegram delivery is claimed here. GitLab browser access, the original RuStore signing key and final store acceptance must still be verified. The old published Firebase client continues using its old backend until users install an update. Armenia registration and later user feedback require their respective external steps; they cannot be marked complete by this QA run.
