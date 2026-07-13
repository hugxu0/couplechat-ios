# R8.1 Release Candidate Matrix

Candidate:

- Implemented code commit: `11e1914`
- Release documentation/deployment head: `6a2e833`
- Validated CI head: `18245f3` (the following amend changed only the R7.4 status line)
- Full validation run: `29175140556`
- Artifact: `CoupleChat-unsigned-230`
- Automated result: server test/build, SwiftLint, iPhone unit tests, chat header fixtures,
  iPad build, unsigned Archive and IPA packaging all passed.

The table below preserves the original full two-device matrix. Under normal conditions it would
be required before acceptance: use one fixed account on iPhone and the other on iPad, then swap
accounts for the two-way messaging rows.

Exception accepted on 2026-07-12: the user has only one available device and explicitly waived
the second-device matrix. The release candidate was installed on the available device and the
user reported no material difference from the previously accepted client behavior. Remaining
cross-device risk is recorded rather than represented as tested.

| Area | iPhone | iPad | Result / note |
|---|---|---|---|
| Cold launch online | [ ] | [ ] | |
| Cold launch offline, cached content remains readable | [ ] | [ ] | |
| Expired token returns to login with an actionable message | [ ] | [ ] | |
| Two-way text and read receipt | [ ] | [ ] | |
| Reply and recall | [ ] | [ ] | |
| Single image and multi-image | [ ] | [ ] | |
| Live Photo, video, voice and file | [ ] | [ ] | |
| Sticker and interaction actions | [ ] | [ ] | |
| Kill App while sending, then recover without duplicate message | [ ] | [ ] | |
| Offline failure, retry after reconnect and delete failed bubble | [ ] | [ ] | |
| Search and jump to an old message | [ ] | [ ] | |
| Load older pages and return to latest without list jumps | [ ] | [ ] | |
| AI private chat and public `@大橘` | [ ] | [ ] | |
| AI image understanding and confirmation card | [ ] | [ ] | |
| History sync continues after leaving Storage | [ ] | [ ] | |
| Pause sync and resume after relaunch | [ ] | [ ] | |
| Bright, dark and custom wallpaper chat headers | [ ] | [ ] | |
| Media open, page, zoom, cancel dismissal and complete dismissal | [ ] | [ ] | |
| Records, reminders, anniversaries and theme settings | [ ] | [ ] | |
| Storage totals, clear cache and resync | [ ] | [ ] | |

Original two-device release gate (waived, not represented as tested):

- [ ] No duplicate or lost formal message was observed.
- [ ] No crash, frozen screen or unrecoverable loading state was observed.
- [ ] Both accounts can send to each other after the full matrix.
- [ ] AI private and public smoke checks pass after the full matrix.
- [ ] No pending message needs to be preserved before R8.2 deployment.

R8.1 decision: not fully accepted. The 2026-07-12 production deployment used an explicit
single-device waiver, while the unchecked iPad and simultaneous dual-device rows remain open.

## R8.2 production release

Released on 2026-07-12 with the following evidence:

- [x] PostgreSQL, uploads and production configuration backup created and SHA-256 verified.
- [x] Previous production image retained as `couplechat-server:rollback-20260712-094038`.
- [x] Candidate `couplechat-server:candidate-6a2e833` passed isolated canary `/live` and `/ready` checks.
- [x] Formal container switched to the candidate with zero restarts after deployment.
- [x] Local and public `/health`, `/live` and `/ready` checks passed.
- [x] `/api/accounts` still returned only `xu` and `si`.
- [x] Production logs showed AI/Memory and reminder initialization without a restart loop.
- [x] User completed single-device production smoke: text, public `@大橘`, private AI, image upload and preview.

R8.2 deployment decision: accepted under the recorded R8.1 waiver. The rollback image,
release backup and prior IPA artifacts must be retained; this does not close the unchecked matrix.
