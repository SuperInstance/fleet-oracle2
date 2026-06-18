# Snail Shell Protocol — Fleet Node Identity for Any Runtime

**Status:** Extracted pattern (from Heddle Snail Shell design, 868 lines, old workspace)

---

## Problem

Every agent runtime (OpenClaw, Heddle, pincher, lever-runner) runs as an island. There's no standard way for one runtime to discover another, query its state, or send it work.

## Solution

A minimal extension layer that makes any runtime a self-identifying fleet node:

### Identity Shape

```typescript
type SymphonyShellIdentity = {
  timbre: 'builder' | 'auditor' | 'weaver' | 'watcher';   // role/tone
  track: { channel: string; group: string };                 // fleet membership
  frequency: {
    cuePollIntervalMs: number;                               // check for cues
    registryHeartbeatIntervalMs: number;                     // announce presence
    identityBriadcastIntervalMs: number;                     // publish state
  };
};
```

### Wire Protocol

JSON-RPC 2.0 over WebSocket (endpoint: `ws://<host>:<port>/ws/snail-shell`)

| Method | Params | Returns |
|--------|--------|---------|
| `workspace.list` | {} | workspaces with ids, names, roots |
| `workspace.status` | {workspaceId?} | git status, recent changes |
| `session.list` | {} | sessions with ids, models, timestamps |
| `session.get` | {sessionId} | full session detail + identity blob |
| `fleet.t-minus` | {target, sender, timestamp} | cue acceptance |
| `fleet.identity` | {} | identity + fleetNodeId |
| `fleet.health` | {} | uptime, memory, session count |

### Cue Types

| Cue | Effect |
|-----|--------|
| `session.send-prompt` | Queue a prompt to a named session |
| `heartbeat.run-tasks` | Trigger heartbeat task execution |
| `memory.maintain` | Trigger memory maintenance cycle |
| `fleet.status` | Return full identity + runtime status |

### Discovery

Identity blobs are embedded in session metadata, making any runtime node discoverable by any other runtime node that can read its workspace directory. No external service discovery needed.

### Minimal Implementation

- **Dependencies:** `ws` (~400KB, pure JS, zero native deps)
- **Code:** ~500 lines total (types + RPC server + daemon plugin)
- **Activation:** `--snail-shell` flag or `SNAIL_SHELL_TIMBRE=auditor` env var
- **Risk:** None — all additions are opt-in and non-breaking

---

## Tenets

1. Every runtime is a fleet node by default (opt-in, not opt-out)
2. Identity is self-describing (no external registry needed)
3. Protocol is JSON-RPC 2.0 (battle-tested, language-agnostic)
4. Cues are at-most-once delivery (stale cues rejected after 60s)
5. No new dependencies beyond `ws`
