# Changelog

All notable changes to SimMonkeyKit. The panel and the client ship together;
entries note when a client change needs a matching panel.

The version prints in the attach line on launch:

```
[simmonkey] 1.0.0 attached — panel at 127.0.0.1:8377
```

**If your attach line has no version number, you're on a pre-1.0 draft** — one
of the copied-source builds from before the package was versioned. Everything
under *Fixed* below is missing from it. Replace the copy with a package
reference and the problem goes away for good.

## 1.0.0 — 2026-09-11

First versioned release.

### Added

- Interception of every `URLSession` request via a `protocolClasses` swizzle,
  covering `URLSession.shared`, custom sessions, Alamofire and `AsyncImage`.
- Wire protocol: `/resolve` before each request, `/report` after. Actions
  `passthrough`, `stub`, `fail`, `forward`.
- **`forward` action** — the request goes to the real server with its URL and
  headers rewritten first. Lets a rule move a path to staging or inject a
  token without stubbing the response. *(Needs panel 1.0.0.)*
- **Response capture** for the panel's detail pane: status, headers and up to
  512 KB of body, reported once when headers land and again on completion.
  *(Needs panel 1.0.0 to display.)*
- **`Cookie` header reconstruction.** `URLSession` injects `Cookie` below the
  level a `URLProtocol` can see, so the client rebuilds it from
  `HTTPCookieStorage` for `/resolve`. Cookies now show in the panel.
- Report sequencing (`seq`), so a streamed response's two reports can't land
  out of order and blank a row.
- `SimMonkey.version`, printed in the attach line.
- Request bodies delivered as a stream are drained and put back on the
  forwarded copy, so `POST` bodies survive interception.

### Fixed

Relative to the unversioned drafts, all of which any copied-source build will
still have:

- **Every request stalled 2 seconds when the panel wasn't running.**
  `NWConnection` reports a refused loopback connection as `.waiting`, not
  `.failed`, so the bridge waited out its full timeout on every request. Now
  fails open in a few milliseconds. This was a direct violation of the
  fail-open guarantee.
- **Streamed responses hung forever.** Passthrough used a completion-handler
  `dataTask`, which only delivers when the response *ends*. A radio stream or
  SSE endpoint never ends, so `AVPlayer` sat in `waitingToPlay` indefinitely.
  Responses are now relayed as they arrive.
- **Authenticated requests got 401 through the panel.** The passthrough session
  was `.ephemeral`, giving it a private cookie jar; any session cookie
  established elsewhere was invisible to forwarded requests. Now shares
  `HTTPCookieStorage.shared` with the app.
- **Console flooded with `Connection refused` when the panel was closed.** The
  client now stops dialling for three seconds after a refusal, and only one
  request probes at a time, so a burst of twenty costs one failed connect.
- **A stale headers-only report could overwrite a finished row's byte count**
  (reports raced on a concurrent queue). Fixed by `seq`.
- **Cancelling during an injected delay could still deliver a response.** The
  `stopped` flag was read across threads unsynchronised; now lock-protected.

### Removed

- The `forward` action no longer replaces the request body. Editing a request
  by hand and firing it moved to the panel's **Edit & Send**, which is the
  right tool for a one-off; a rule is for rewriting *every* matching request.

### Panel 1.0.0, for reference

Ships alongside. Request/response detail pane with a collapsible JSON tree,
body decoding that survives non-UTF-8 and binary responses, rules that match on
the request body and can forward with rewrites, Edit & Send composer, stub
editor without smart-quote substitution, text-size zoom, follow-the-simulator
toggle, app and menu bar icons.

