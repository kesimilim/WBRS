# Native profile photos in Flutter

The own and public native profile screens now use the existing native photo
HTTP contract. People-list rows do not fetch photos. The public/own profile DTOs
still honestly expose `avatar=null` / `mediaReady=false`; the separate current
photo descriptor response is the only authority for this reader.

`TimewebAppRuntime.openProfilePhotos(targetUid)` captures the current native
session lease and returns a page-owned `TimewebProfilePhotoReader`. It uses the
existing current-read/runtime-write/own-profile gates. No client flag, Firebase
identity, preference-derived identity, public URL or legacy media route is added.

The reader accepts only exact GET responses from
`/v1/runtime/people/{uid}/photos?limit=30&cursor=...` and
`/v1/runtime/people/{uid}/photos/content?reference=...`. A descriptor page is at
most 30 rows / 64 KiB with a strict allowlist, exact target, dense ordinals,
explicit primary photo, four image MIME types and at most 50 total associations.
Continuation and image references are opaque RAM-only objects bound to the
reader, actor, target, native epoch and conservative sixty-second lifetime.
The cursor also binds the requested page limit. Neither capability can be
created by passing an arbitrary string to the public client API.

An original must declare an exact positive Content-Length matching its descriptor
and no more than 8 MiB **before collection**. Each chunk and the final length are
checked too. Redirects, public caching, missing `no-store`, content encoding,
ranges, extra descriptor keys, unsupported MIME and malformed JSON fail closed.
An error body is not decoded. A current target/storage 404 leaves a healthy
native session signed in; 401 uses the existing native refresh/retry contract.

Photo transfers share the same four-transfer global HTTP budget as auth and
other current reads. Identical work is coalesced only inside the same page owner.
Reader close, target/epoch changes and runtime stop abort the request and cancel
the response stream. Their drain observes real send/stream completion; a timed
out or late send cannot release its budget slot early or publish a late result.

The new widget owns a primary image and at most one explicitly selected gallery
image. Only the primary original loads automatically. Gallery selection and
descriptor load-more are explicit; fetching a new page does not download its
originals. Covering the route, changing the target/actor, or disposing the widget
closes its owner and disposes both decoded frames. Resuming a route obtains fresh
descriptors. The avatar uses centered `BoxFit.cover`; the gallery uses
`BoxFit.contain` with its aspect ratio in a bounded display area.
The public portrait keeps its existing height and canonical group ring.

Before invoking the native decoder, the client verifies PNG/JPEG/GIF/static WebP
magic/container headers and dimensions: at most 8192 per side and 16,777,216
pixels. GIF canvas and every frame rectangle are bounded (at most 512 frames),
and only the first frame is decoded. Animated WebP, APNG, unknown/truncated
headers and other unsupported images remain unavailable. The native descriptor
must agree with the checked dimensions (orientation transpose is allowed).
Its first frame is resized to a longest side of at most 1024. Buffers,
descriptors, codecs and rejected/late images are always disposed. Display uses
`RawImage`, with no `ImageProvider`, global user-image cache, disk or preferences.

Local evidence: nine focused client cases passed. Seven focused widget/parser
cases cover real first-frame decoding, strict bounds, explicit gallery loading,
target change, route cover/resume, real A→B native login, healthy 404 and both
actual profile screens. The valid synthetic PNG fixture replaced a corrupt
sample; the resume test now gives the native event loop time rather than pumping
an indeterminate loader through the genuine transport deadline. Only the affected
gallery/resume cases were repeated; the nine passed client cases were not rerun.
Scoped analysis reports no errors/warnings in the changed/new paths; the three
pre-existing `curly_braces_in_flow_control_structures` notices in the shared auth
client remain outside this change.

These are local client/HTTP-contract checks. They do not prove enabled production
photo routes, real current associations, deployed native authorization or a
completed migration. Server factory/capability setup, grants, controlled live
readback and activation remain separate operator steps. No APK, cloud request,
SQL read/write, grant, deployment or activation was performed for this client work.
