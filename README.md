# events-ios

The Barry event feed on a phone. Read, filter, and clear the backlog of
progress events, notifications, task completions and system alerts that agents
write as they work.

No custom backend was written for this app. It is a client of the existing
`/api/v1/events` routes in `servers/api`, the same surface the web feed and the
Sessions macOS app use.

## Running it

```bash
barry ios build events-ios --simulator "iPhone 16 Pro"   # simulator
barry ios build events-ios --device                       # sign + install on a paired phone
./scripts/test.sh                                         # full suite vs the real API
```

The bag must be registered for the CLI to find it
(`barry install ~/repos/bags/events-ios --as events-ios`) — `barry ios build`
only walks registered local bags.

## Reaching the Mac

Every Barry service binds `127.0.0.1`. There is **no route to a raw service
port** from a phone.

| | Base URL | Secret |
|---|---|---|
| Simulator | `http://127.0.0.1:9429` | not needed — the proxy injects one |
| Device | `https://barry-mac.tail5cb2f2.ts.net:8443` | **required** |

The device path goes over the user's PERSONAL tailnet to a userspace
`tailscaled` sidecar (separate from the Mac's work Tailscale client), which
terminates TLS and proxies to the API on `127.0.0.1:4854`.

**The certificate is a real Let's Encrypt one**, issued for the tailnet name, so
there is no certificate warning on the phone and nothing to pin or trust
manually. That is why the app ships no `NSAllowsArbitraryLoads` — see below.

**The secret is required on the device path.** `:4854` rejects an
unauthenticated caller with 403 *even from loopback*; `/health` is the only open
route. This is the opposite of the old Caddy route, where the barry.works proxy
filled the secret in for trusted-network callers. A phone with no secret set
gets a 403 JSON blob, which is correct and expected.

> **This replaces a stale hardcoded IP.** The device default used to be
> `http://100.97.236.110` plus a `Host: barry.lan` header to select a Caddy site
> block. That address changed within a day of being written down (and is now an
> offline node). The sidecar's DNS name is stable, so there is no address to
> keep up to date — Settings still overrides and persists the base URL.

### App Transport Security

The app sets **`NSAllowsLocalNetworking`**, not `NSAllowsArbitraryLoads`.

The device path is genuine HTTPS and needs no exception at all. The one
remaining cleartext caller is the *simulator*, which talks to the proxy on
`http://127.0.0.1:9429` — and ATS blocks that unless permitted.
`NSAllowsLocalNetworking` permits exactly loopback and link-local, and nothing
routable, so a misconfigured `http://` tailnet URL still fails loudly instead of
silently downgrading.

## Three things the API does that the app is built around

Each was verified against the live server, and each fails *silently* if ignored.

**1. Success responses have no `ok` field.** The route writes
`res.json({ ok: true, … })`, but contract middleware strips it — the live
top-level keys are exactly `events` and `nextCursor`. A required `ok` in
`EventListResponse` fails to decode *every* successful response. Error responses
do still carry `ok`.

**2. An invalid cursor returns HTTP 200 and page one.** `decodeEventCursor`
returns nil and the route then queries with no `before:`. Nothing in the
response says the cursor was rejected, so naive infinite scroll appends the same
page forever. `AppStore.loadMore` stops when a page contributes no new ids.

**3. `markAllRead` honours only `type`.** Severity, session and unread filters
are ignored by `packages/db`. With a severity filter on screen the confirmation
must name the true global scope — it says "all", never "these".

## Why polling, not the WebSocket

There is a topic bus at `/api/v1/ws`, and the web and macOS feeds subscribe to
`"events"`. Nothing publishes that topic: the only non-test `publishToTopic`
call sites publish `"identities"`. A subscription connects and then stays silent
forever, which looks exactly like a quiet feed. Polling is the source of truth
here deliberately — not a placeholder to replace later.

Consequence worth knowing: **the app only updates while it is open.** See
"What the notifications actually do" below — that constraint is what shapes
them.

## What the notifications actually do

The app posts **local** notifications (`UNUserNotificationCenter`) when a poll
finds unread events you have not been told about yet. Read this before relying
on them:

**They fire only while the app is running.** The 12-second poll is a foreground
`Timer`. iOS suspends it a few seconds after you leave the app, and nothing
wakes it again. So you get banners for events that arrive while the app is open
but the feed is not what you are looking at — switching apps, pulling down
Notification Centre, the seconds after backgrounding — and **nothing at all
once the app has been suspended.**

**A locked phone in your pocket will not buzz.** If the app has been closed or
suspended, new events wait silently until you next open it. That needs real
push, which needs APNs, which needs a paid Apple Developer team and an
`aps-environment` entitlement — and this bag is deliberately free-team-signable
(`bag.yaml`). It is not a limitation waiting to be coded around; it is the
price of the app installing from a free personal team.

`BGAppRefreshTask` was considered and deliberately skipped. It is free (not a
paid entitlement), but iOS schedules those wakeups at its own discretion —
commonly a few times a day, sometimes not for days, and never on a predictable
cadence. It would move the app from "no background alerts" to "occasional,
unpredictable background alerts", which is a worse thing to describe honestly
than the current line and no better to depend on.

What the notifications do get right, ported from the macOS app:

- **Nothing on launch.** The first page is a backlog of thousands; the
  high-water mark starts there rather than announcing it.
- **No repeats.** Every poll refetches the same first page. Only events newer
  than the last one announced are announced.
- **Never more than four at once.** Three banners, then one "+N more events"
  line.
- **Silence while you are looking.** Nothing is posted in the `.active` scene
  phase, since banner-ing a row already on screen is noise. The mark still
  advances, so backgrounding the app does not re-announce what you just read.
- **Already-read events are never announced** — marking one read on the web
  feed keeps it quiet here.
- Error severity gets `.defaultCritical`; everything else the default sound.
- Tapping a banner opens that event's detail view.

If you denied the permission prompt, Settings says so and offers a button into
iOS Settings. Authorization is per bundle identifier and can only be changed
there, so without that the app would just look like a quiet feed forever.

## Reading a noisy feed

The backlog is overwhelmingly repeats: a 100-event sample held 22 distinct
titles, one of them 40 times. **Group repeats** (in the filter menu) folds
consecutive occurrences of the same alert into a single row with a `×N` count.

It is a display concern only — nothing is dropped, the unread count is
untouched, and a fold always surfaces an unread member rather than hiding one
behind a read head. Off by default: a reader should not silently omit rows until
asked. Digits are ignored when matching, so `at 64%` and `at 71%` fold together,
while a ✅ *Recovered* notice stays separate from the ⚠️ it resolves.

## Layout

| Path | What it is |
|---|---|
| `App/Event.swift` | the model; lenient enums, dual ISO8601, Slack-markup titles |
| `App/EventsClient.swift` | `URLSession` client over `/api/v1/events` |
| `App/AppStore.swift` | feed state, paging, filters, polling |
| `App/EventAnnouncement.swift` | pure rules for what deserves a notification |
| `App/Notifier.swift` | posts them; authorization, delegate, tap routing |
| `App/ServerConfig.swift` | base URL + keychain secret |
| `App/ConnectionProbe.swift` | what "Test connection" actually proved |
| `App/Views/` | feed, detail, settings |
| `Tests/` | model decoding vs real payloads; live API integration |

`Event.swift` and the paging logic are ported from
`bags/sessions/sessions-macos/app/Features/Events/`, which had already been
hardened against this API's quirks.
