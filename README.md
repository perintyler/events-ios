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

| | Base URL | Host header |
|---|---|---|
| Simulator | `http://127.0.0.1:9429` | — |
| Device | `http://<tailscale-ip>` | `barry.lan` |

The device path goes Tailscale → Caddy on :80 → the barry.works proxy, which
injects the API secret for trusted-network callers. The `Host` header is what
selects the site block, so it is load-bearing rather than cosmetic.

> **The Tailscale address changes.** This Mac moved from `100.101.38.91` to
> `100.97.236.110` inside a day, and `bags/plans/plans-iphone` still ships the
> stale one. The shipped default is a starting point; Settings overrides and
> persists it. Find the current value with `tailscale ip -4`.
>
> `bags/point-guard-ios` targets `100.x.x.x:3868` — a raw port — so its device
> path cannot connect at all. Don't copy that shape.

The secret is optional on the tailnet today (the proxy supplies one) but is sent
when set, so the app keeps working if `BARRY_TAILSCALE_IPS` ever narrows trust.
It lives in the keychain under this app's own key, never shared with the other
Barry apps.

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

Consequence worth knowing: **the app only updates while it is open.** There are
no push notifications (that needs a paid team and an APNs entitlement), so this
is a reader, not an alerter.

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
| `App/ServerConfig.swift` | base URL + host header + keychain secret |
| `App/Views/` | feed, detail, settings |
| `Tests/` | model decoding vs real payloads; live API integration |

`Event.swift` and the paging logic are ported from
`bags/sessions/sessions-macos/app/Features/Events/`, which had already been
hardened against this API's quirks.
