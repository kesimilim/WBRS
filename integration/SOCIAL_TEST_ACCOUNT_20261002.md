# Requested social test account

The UID `4LTxrSEmWmNRcGn5paeFfhWRIDi1` requested by Dmitry was matched
to the supplied account email through a read-only Firebase Auth lookup on
2026-10-02. The account exists and is enabled. No password or credential was
read, changed or committed.

The UID was added to `admin()` in `tool/security/social_roles.rules`, exactly
as requested. This file remains an isolated local rules fixture, not a full
production rules replacement. It does not grant the account a global Firebase
Auth `admin` claim or access to the application's financial/user administration.

The focused Auth/Firestore emulator scenario verifies that this exact UID can
approve an author and publish its own post. An ordinary account cannot issue
grants or publish without approval. A forged author UID and writes to unrelated
user data remain denied by the fixture.

The current production Firestore rules were read before this change. They are
the existing general authenticated-access rule set and do not use this isolated
function. Deploying the fixture would remove rules for existing application
collections, so it was not deployed. The production client's publishing guard
still uses an approved author grant or an Auth admin claim; adding a UID to this
fixture alone is not proof that the production app enables administrator UI.

A fresh upstream read found seven existing branches and PR heads 1–4. There
was no separate identifiable Ksyusha wall source or new PR. The current APK
therefore includes the existing integration wall; its authorship is not claimed
to be Ksyusha's. A concrete source branch/commit is needed to include her version.
