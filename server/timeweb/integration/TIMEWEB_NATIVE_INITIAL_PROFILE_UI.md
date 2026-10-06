# Native initial profile UI — isolated source proof

Status: isolated, locally checked; no public flag activation, provider calls, SQL, deployment or APK build. This UI is not in APK47.

`TimewebOwnProfilePage` exposes registration for current `profileDetailsSaved=false` and `isRegistrationEnd=false`, excluding search. The existing eight-field editor is hidden and guarded while initial registration is required, an original finish is pending, or the bounded local journal restore has not completed. A restored original finish remains reachable when the current profile already has `saved=true`; this recovery route exposes Check only. This prevents a competing editor save from changing the original finish CAS.

`TimewebInitialProfilePage` uses the same native runtime/owner, CLRS logo, existing glass panel and `assets/family_main.jpg`. The eight existing fields and exact canonical country/region selectors scroll at narrow width and large text. The page offers exactly three sequential local JPEG/PNG/WebP selections, at most one active upload. The original READY prepare/commit pointers are saved by the reviewed client callback before photo ACK. Count/history alone never enables Save: all three pointers must be freshly verified. No URL, path or binary is added to a durable UI draft. Closing/back or changing owner clears text, photo buffers and its owned route/popups; an unrelated newer route is not removed.

The page reads a fresh own stamp immediately before a new finish. Unknown photo/finish outcomes retain their original client journal and offer original lookup only. A restored finish hides fields and uploads. Confirmed finish ACK returns to a fresh current own-profile read and the existing native temperament entry. This is UI navigation proof, not live temperament execution.

## Focused checks

One new actual-widget aggregate scenario passed on Flutter 3.32.5: native gate → blank own profile → initial form → first photo lost ACK → back/reopen/original check → three READY pointers → actual eight fields/country/region selectors → lost finish ACK/current saved=true → A→B removes A route/fields → late A response ignored → A returns to recovery-only Check → ACK → fresh own profile/native test entry. It runs at 360×760, text scale 2 and a 240px keyboard inset, verifies no Firebase initialization, no overflow exception, exactly three PUT/commit actions and exactly one finish POST. Both initial and pending-finish states exclude the ordinary editor.

The fixture uses mock native HTTP receipts and synthetic photo bytes. It does not prove production S3 conditional PUT, image decoding, object privacy or a real provider upload. Those are separate server/provider acceptance requirements. Earlier retries corrected only this new test's API, real disk IO in virtual time, route/frame waits and lazy dropdown scrolling; no old modules were run.

Command: `flutter test --no-pub test/timeweb_initial_profile_widget_test.dart` — 1/1 PASS (8s). Log: `initial-ui-widget.log` alongside the private patch.

Scoped analyzer: only the new page, modified own-profile page and new test — No issues. Log: `initial-ui-analyze.log`. All 29 referenced existing UI catalog keys are present in all 23 bundled catalogs; no catalog edits or cloud translation.

## Source boundary

The four source paths and the exact seven final initial-client dependency hashes are bound by `initial-ui-source-freeze.json` alongside the patch. Client manifest SHA256: `5409b05171200df269b0e133bbb1855ef6ed33c5e7b98a8319f2a1f5d309431a`; client patch SHA256: `affcd72846d04fe8eb714e0a2f91b1cc1ae90295ab8db7b4f3ea779361507896`. Only these four UI/test/doc paths are in this patch. The own-profile baseline is separately hash-bound and checked unchanged in the actual checkout.

Remaining: real private provider proof/credentials and guarded factory activation remain outside this local UI acceptance. Imported/legacy photo associations are not silently substituted for the three original native upload receipts. Public gates stay unchanged and default off.
