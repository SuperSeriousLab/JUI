# JUI Transport Test Journal

Headless integration tests for the JUI TCP+TLS session transport layer.
Run `julia bin/test-session.jl [host] [port] [token]` to add a new entry.

## Test Descriptions

| ID | Name | What it verifies |
|----|------|-----------------|
| T1 | connect + input | Auth, snapshot received, keystrokes reach shell |
| T2 | session persistence | Shell state survives client disconnect/reconnect |
| T3 | bad token rejected | Wrong token → AuthError, not silent accept |
| T4 | token stability | Token valid across 5 rapid connect/disconnect cycles |
| T5a/b | concurrent clients | Two simultaneous clients share session without corruption |
| T6 | shell exit / clean EOF | Connection closes cleanly; full exit test needs dedicated server |
| T7 | 10 KB input burst | Large paste doesn't hang or drop bytes |
| T8 | resize mid-session | WireResizeEvent triggers server re-render at new geometry |
| T9 | slow client | Throttled reader (0.5s/frame) doesn't crash server pump |

---

## 2026-04-18 13:16:59 — 10/10 passed
**Host:** 192.168.14.30:7878  
**Runner:** aethelred  

- [✓] T1: sentinel visible after input
- [✓] T2: session persisted across reconnect
- [✓] T3: bad token rejected (`AuthError`)
- [✓] T4: token valid across 5 connect/disconnect cycles
- [✓] T5a: client1 saw concurrent sentinel
- [✓] T5b: client2 saw same sentinel (shared session)
- [✓] T6: shell alive, connection closed cleanly (full exit test requires dedicated server — see journal)
- [✓] T7: 10 KB burst handled, server alive, buffer valid
- [✓] T8: server re-rendered at 120×40 after resize event
- [✓] T9: slow client survived 5s, server still responsive (10 frames received)
