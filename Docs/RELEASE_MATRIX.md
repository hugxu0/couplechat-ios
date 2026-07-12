# R8.1 Release Candidate Matrix

Candidate:

- Code commit: `11e1914`
- Validated CI head: `18245f3` (the following amend changed only the R7.4 status line)
- Full validation run: `29175140556`
- Artifact: `CoupleChat-unsigned-230`
- Automated result: server test/build, SwiftLint, iPhone unit tests, chat header fixtures,
  iPad build, unsigned Archive and IPA packaging all passed.

R8.1 remains in progress until every manual row below passes. Use both fixed accounts. Run the
iPhone column with one account and the iPad column with the other, then swap accounts for the
two-way messaging rows.

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

Release gate:

- [ ] No duplicate or lost formal message was observed.
- [ ] No crash, frozen screen or unrecoverable loading state was observed.
- [ ] Both accounts can send to each other after the full matrix.
- [ ] AI private and public smoke checks pass after the full matrix.
- [ ] No pending message needs to be preserved before R8.2 deployment.

R8.1 decision: accepted with the explicit single-device waiver above. Untested iPad and
simultaneous dual-device behavior remain residual release risks.
