<!-- tools: Bash,Read -->
# QA — events-ios

Every check below has a **negative control**: the change that makes it fail. All
of them were run and confirmed red, then reverted. A regression test that has
never failed is a claim, not evidence.

Full suite: `./scripts/test.sh`. It prints whether the live API is
reachable *before* running, because the live tests `XCTSkip` when it is not —
and a skip reads identically to a pass in the summary line.

## Coverage

| Layer | File | Talks to | What it proves |
|---|---|---|---|
| Model | `Tests/EventModelTests.swift` | fixtures copied from live responses | the wire shape decodes, including the hostile bits |
| Notifications | `Tests/EventAnnouncementTests.swift` | nothing — pure logic | what gets a banner, and everything that must stay silent |
| Integration | `Tests/LiveEventsAPITests.swift` | the real API on :9429 | pagination, filters, and the two server traps |
| Probe | `Tests/ConnectionProbeTests.swift` | `URLError` values, plus the real :4854 and :9429 | "Test connection" tells its failure modes apart |

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
| 9 | at most 3 banners per batch | `banners: unseen` (drop `prefix`) | `testFiveNewEventsBecomeThreeBannersAndASummary` red: 5 banners, not 3 |
| 10 | read events are never announced | drop `&& $0.isUnread` from `unseen` | `testAlreadyReadEventsAreNeverAnnounced` red: `["read", "unread"]` |
| 11 | the high-water mark suppresses repeats | drop the `createdAt > mark` filter | 3 red, incl. `testEventsOlderThanTheMarkAreNeverReAnnounced`: all 3 announced |
| 12 | nothing is announced while the feed is up | drop `!isFeedOnScreen` from the guard | `testNothingIsAnnouncedWhileTheFeedIsOnScreen` red: 3 banners |
| 13 | an older page cannot rewind the mark | `return newest` instead of `max(mark, newest)` | `testTheMarkNeverGoesBackwards` red |
| 9 | a 403 reads as "reachable, fix the secret" | collapse the 403 branch into `.serverError` | `testForbiddenIsReachableAndSaysTheSecretIsTheProblem` red: `("serverError(status: 403…)") is not equal to ("reachableButUnauthorized")`, and the live `testRealServerWithNoSecretReportsUnauthorized` red too |
| 10 | a wrong tailnet and a dead sidecar differ | fold `.cannotFindHost` into the `.cannotConnect` case | `testWrongTailnetAndDownSidecarAreDifferentOutcomes` red: "a wrong tailnet and a dead sidecar must not read identically" |
| 11 | an unhealthy server is not blamed on the secret | delete the non-2xx check on `/health` in `ConnectionProbe.run` | `testAnUnhealthyServerIsNotBlamedOnTheSecret` red: "a 502 from the health route should outrank the events route's 403, got reachableButUnauthorized" — **see below** |

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

**It happened again with control #11**, twice, which is why it is worth writing
down as a pattern rather than an anecdote:

1. The first attempt aimed at a real port assumed to lack `/health` (:9429).
   That port *does* serve `/health` with a 200, so the test's own guard skipped
   it every run. A permanently-skipping test proves nothing — and the suite's
   skip count is the only thing that revealed it.
2. The replacement used a stub returning **one** status for every request. With
   the health check deleted it stayed **green**, because the events call then
   returned that same 502 by itself and produced the same outcome. The test
   never distinguished which request the answer came from.

The fix was a stub that answers `/health` and `/api/v1/events` with *different*
statuses (502 and 403). Only then does deleting the health check flip the
outcome to `reachableButUnauthorized` and turn the test red.

## Three verification traps hit while building this

**A stale binary looked like a broken feature.** After `barry ios build` put the
app in `.build-barry-ios`, a later bare `xcodebuild` wrote to Xcode's DEFAULT
DerivedData instead. Three rounds of screenshots showed an ungrouped feed and
sent me hunting a non-existent `@AppStorage` bug; the installed binary was 10
minutes old and simply did not contain the feature. **Always pass
`-derivedDataPath .build-barry-ios` so what you screenshot is what you built**,
and check `stat -f %Sm` on the installed binary when behaviour contradicts the
source.

**Removing an ATS exception needs the simulator re-checked, not reasoned about.**
The device path is real HTTPS, so `NSAllowsArbitraryLoads` looks free to delete —
but the SIMULATOR still speaks plain HTTP to `127.0.0.1:9429`, and ATS blocks
loopback cleartext unless something permits it. `NSAllowsLocalNetworking` is the
narrowest key that does (loopback and link-local only, nothing routable).
Verified by installing and screenshotting: the feed rendered, and separately a
launch at `-eventsBaseURL https://barry-mac…` failed with "hostname could not be
found" — a DNS error, which proves the HTTPS request was attempted rather than
refused by ATS. Check the INSTALLED plist, not the source:
`/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" <app>/Info.plist`.

**`strings`/`nm` cannot tell you whether a Swift feature is in a binary.**
Grepping the built app for `recurrenceKey` returned 0 — but so did `AppStore`
and `BarryEvent`, which certainly exist. The detector could not distinguish
"absent" from "not exposed as a symbol", so its answer carried no information
either way. Verify by running the app, not by grepping it.

## Manual checks (only a device can prove these)

- [ ] Install with `barry ios build events-ios --device`, trust the *app* under
      Settings → General → VPN & Device Management. There is no TLS certificate
      to trust — the tailnet host serves a real Let's Encrypt cert.
- [ ] **Set the secret in Settings.** Unlike the old proxy route, the device path
      403s without it. "Test connection" says so in those words.
- [ ] **Turn Wi-Fi off.** Over cellular the app must still reach the Mac via
      Tailscale. This is the difference between "the app works" and "the
      simulator's localhost works", and it is the check that would have caught
      `point-guard-ios`'s dead device path.
- [ ] "Test connection" with a deliberately wrong host must say it cannot
      RESOLVE the host, not merely "failed" — the point of the probe is that
      wrong-tailnet and server-down do not look alike.
- [ ] Scroll well past the first page; no duplicate rows, no infinite spinner.
- [ ] "Mark all read" on a severity filter warns that it clears everything.
- [ ] Dark mode, and a Dynamic Type size or two.

### Why the notification rules are not tested through `Notifier`

`UNUserNotificationCenter` cannot run under XCTest, so a test that drove the
`Notifier` directly could only assert that it did not crash — a check whose
broken state looks exactly like its healthy one. Every rule that decides
*whether to alert* therefore lives in `EventAnnouncement`, which is pure and has
controls #9–13 above. `Notifier` is left with only the part a test could not
have proved anyway: handing the decision to the system.

## Manual check the simulator CAN prove

- [x] A local notification actually appears. Post an event
      (`barry events emit "..." --type notification --severity info`) while the
      app is open but backgrounded, and the banner arrives. Simulators deliver
      local notifications; they cannot deliver push.

## Known gaps

- **No background delivery.** The poll is a foreground `Timer`, so once iOS
  suspends the app no new events are found and nothing is announced until it is
  reopened. A locked phone will not buzz. Real push needs APNs and a paid team —
  see README.
- No UI test target yet; the views are exercised manually.
