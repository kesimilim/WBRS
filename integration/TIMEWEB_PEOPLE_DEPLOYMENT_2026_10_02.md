# Timeweb people read: closed stand deployment

The server-side public-profile directory and detail code is published in GitHub commit
`4b3ad4c` (visibility evaluator from `4fcc18b`) and GitLab commit
`330dfdd670e9de01903f78f47948d330c365d33f`, branch `codex/clrs-api-readonly-draft`.
Before committing through GitLab Web IDE, the complete editor buffers for these
four files were copied through the editor and compared byte-for-byte with the
reviewed local files:

| File | SHA256 |
| --- | --- |
| profile_visibility.py | 0bba0f73e5b5d12dedb6dfe4a148cf3128d3d723a6727b5b7ea56634df7e7a21 |
| runtime_people.py | 986cc6ca105a70f0f56f3cd3d643af5893831e1d794be38a3da1db0001b0597d |
| runtime_read_http.py | 57a7684ad01737578ce960369353d3ff250e4debca31af526c6c63eb69c232d9 |
| RUNTIME_READS.md | 428c96539bba7c0e56d20d891e998fcf533663782552b78754278b0635305c14 |

Existing Timeweb App Platform application 151291, stand 5179, reports online at
commit `330dfdd`. Its existing environment was preserved; this change created no
paid resource and enabled no native runtime flag. The stopped main application
remains separate from this stand.

One post-deployment check on 2026-10-02 returned:

- `GET /healthz`: 200, `service=clrs-timeweb-stand`, `state=api_draft`.
- `GET /v1/runtime/people?limit=1`: 404, `error=not_found`, as required while the
  native runtime gate is disabled.

No authorization was sent, no user data was read, and there were no database
writes. Private source binding, response proof and screenshots are retained
outside source control. This confirms code publication and the closed stand's
startup; it does **not** confirm a live authenticated people request, production
visibility, photo availability, query latency, client cutover or migration completion.

`RUNTIME_READS.md` documents the limited SQL fixture proof and focused backend
checks. Review APK 1.0.25-44 was built earlier from client commit
`a718ae890ece5a2406ac5ad036577a5291b6bc92`; it continues to use Firebase and does not
include later native people client changes.
