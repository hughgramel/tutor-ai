# HeyClicky OSS reference code

Vendored from https://github.com/farzaa/clicky (MIT, LICENSE included), commit a80fa80
(2026-04-27). Full clone lives at `~/repos/clicky`. These are the files whose patterns we
reuse — kept here so the build can crib exact code without leaving the repo.

| File | What we steal |
|---|---|
| `CompanionManager.swift` | System prompt (lines ~544-577), `[POINT]` regex parsing (~782-823), screenshot-px → screen-point coordinate mapping + Y-flip (~648-682), history cap + tag-stripping before storage (~684-694) |
| `OverlayWindow.swift` | Pointer animation: bezier flight (duration `clamp(dist/800, 0.6-1.4)s`, arc `min(dist*0.2, 80)`), 3s hold, char-streamed bubble (30-60ms/char), smoothstep easing |
| `ClaudeAPI.swift` | SSE streaming client over one long-lived URLSession, image content blocks + prose dimension labels |
| `CompanionScreenCaptureUtility.swift` | Snapshot discipline: max dimension 1280px, JPEG 0.8 |
| `ElementLocationDetector.swift` | DEAD CODE in Clicky, kept as the Anthropic Computer-Use grounding pattern (recommended resolutions 1024×768/1280×800/1366×768, Retina-safe resize) — our split-brain fallback would look like this |
| `worker/` | The 3-route Cloudflare Worker (keys server-side, token minting with TTL) |

What NOT to copy: blocking TTS (whole-MP3-then-play), text-only history (no visual
memory), end-of-response-only tag (we parse tags mid-stream), no worker auth.
