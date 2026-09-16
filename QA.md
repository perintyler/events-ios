<!-- tools: Bash,Read -->
# QA — events-ios

Every check below has a **negative control**: the change that makes it fail. All
of them were run and confirmed red, then reverted. A regression test that has
never failed is a claim, not evidence.

Full suite: `./scripts/test.sh` (18 tests). It prints whether the live API is
reachable *before* running, because the live tests `XCTSkip` when it is not —
and a skip reads identically to a pass in the summary line.

## Coverage

| Layer | File | Talks to | What it proves |
|---|---|---|---|
| Model | `Tests/EventModelTests.swift` | fixtures copied from live responses | the wire shape decodes, including the hostile bits |
| Integration | `Tests/LiveEventsAPITests.swift` | the real API on :9429 | pagination, filters, and the two server traps |

## Verified negative controls

| # | Check | Break it by | Confirmed result |
|---|---|---|---|
| 1 | `ok` is absent from success responses | add `let ok: Bool` to `EventListResponse` | `testDecodesListResponseWithNoOkField` red: `keyNotFound("ok")` |
| 2 | live tests fail (not skip) on a decoding bug | same as #1 | `testListDecodesAgainstLiveServer` red — **see below** |
| 3 | repeated page is not appended | delete the `known`/`fresh` dedupe in `loadMore` | `testLoadMoreIgnoresAPageTheServerRepeated` red: 50 → 100 events |
| 4 | unread badge comes from the server | `unreadCount = events.filter(\.isUnread).count` | `testUnreadCountExceedsLoadedPage` red: "50 is not greater than 50" |
| 5 | fractional-second timestamps parse | drop `.withFractionalSeconds` | `testParsesBothTimestampForms` red: `Unrecognised date` |
| 6 | Slack shortcodes render | remove the `:warning:` replacement | `testDisplayTitleRendersSlackMarkup` red |
| 7 | repeats fold by ignoring digits | make `recurrenceKey` keep digits | `testConsecutiveRepeatsFoldWithACount` red: 4 rows, not 2 |
| 8 | a fold never hides an unread repeat | drop the unread-promotion line | `testFoldSurfacesAnUnreadRepeat` red |

### #2 is the one that found a real bug in the tests

`setUp` originally skipped the whole live suite on *any* error from its probe.
Running control #1 showed six live tests turning into **skips** rather than
failures — a decoding bug would have silently disabled the integration suite at
exactly the moment it had something to report.

`setUp` now rethrows `EventsError.decoding` and `.http` and skips only on real
transport failure. Without control #1 this would have shipped.

### A passing negative control is not good news

The first version of control #3 drove `loadMore()` with a **valid** cursor.
Removing the dedupe guard left it **green**, because a working cursor never
produces duplicates — the test never reached the code it was meant to protect.
That is the "passing negative control" trap: equally consistent with "the guard
works" and "the test never exercises the guard".

The fix was a `loadMore(usingCursor:)` seam so the test can drive the path with
the garbage cursor the guard exists for. It now fails 50 → 100 as it should.

## Two verification traps hit while building this

**A stale binary looked like a broken feature.** After `barry ios build` put the
app in `.build-barry-ios`, a later bare `xcodebuild` wrote to Xcode's DEFAULT
DerivedData instead. Three rounds of screenshots showed an ungrouped feed and
sent me hunting a non-existent `@AppStorage` bug; the installed binary was 10
minutes old and simply did not contain the feature. **Always pass
`-derivedDataPath .build-barry-ios` so what you screenshot is what you built**,
and check `stat -f %Sm` on the installed binary when behaviour contradicts the
source.

**`strings`/`nm` cannot tell you whether a Swift feature is in a binary.**
Grepping the built app for `recurrenceKey` returned 0 — but so did `AppStore`
and `BarryEvent`, which certainly exist. The detector could not distinguish
"absent" from "not exposed as a symbol", so its answer carried no information
either way. Verify by running the app, not by grepping it.

## Manual checks (only a device can prove these)

- [ ] Install with `barry ios build events-ios --device`, trust the certificate
      under Settings → General → VPN & Device Management.
- [ ] **Turn Wi-Fi off.** Over cellular the app must still reach the Mac via
      Tailscale. This is the difference between "the app works" and "the
      simulator's localhost works", and it is the check that would have caught
      `point-guard-ios`'s dead device path.
- [ ] Set the Tailscale address in Settings and confirm "Test connection" both
      succeeds and — with a deliberately wrong address — fails visibly.
- [ ] Scroll well past the first page; no duplicate rows, no infinite spinner.
- [ ] "Mark all read" on a severity filter warns that it clears everything.
- [ ] Dark mode, and a Dynamic Type size or two.

## Known gaps

- No push notifications, so the feed only updates while open (see README).
- No UI test target yet; the views are exercised manually.
