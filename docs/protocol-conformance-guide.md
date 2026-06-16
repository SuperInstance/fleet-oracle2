# SuperInstance Protocol Conformance Guide

## 1. Envelope Structure

Every bottle is a JSON object with exactly these fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string (UUIDv7) | Time-ordered unique identifier (48-bit unix_ms + 80 random bits) |
| `ver` | u32 | Envelope schema version — always `1` |
| `src` | string | Source agent/service identifier |
| `tgt` | string | Target agent/service identifier |
| `act` | string | Namespaced action (e.g. `"cycle.complete"`, `"transform"`) |
| `trits` | Trit[] | Array of ternary digits `{-1, 0, +1}` — conservation-tracked |
| `enc` | string | Payload encoding — always `"msgpack"` |
| `pay` | string | Base64-encoded MessagePack payload (opaque binary) |
| `ttl` | u32 | Time-to-live in seconds from `id` creation |

The **BottleHeader** is a lightweight view of the envelope only (excludes `pay`), parseable in O(1) without touching the payload.

## 2. Wrapping Any JSON Payload

```
JSON Payload → rmp_serde::to_vec() → base64(STANDARD) → `pay` field
```

**Rust (in practice):** `Bottle::new(src, tgt, act, trits, &payload, ttl)` handles both encoding steps — the payload is serialized to MessagePack and base64-encoded automatically into the `pay` field.

**Manual pipeline for any language:**
1. Serialize payload bytes with msgpack (e.g. `@msgpack/msgpack` in JS, `rmp-serde` in Rust)
2. Base64-encode the resulting bytes (RFC 4648 standard alphabet, no padding in Rust's `base64` crate; tolerate padding in TS `btoa`)
3. Place encoded string in the `pay` field
4. Set `enc` to `"msgpack"`

Decoding reverses the chain: base64-decode `pay`, then msgpack-deserialize into the target type.

## 3. TypeScript Client: Reading & Writing Bottles

The repo ships complete TypeScript types and helpers in `src/types.ts`:

```typescript
import { Bottle, Trit, createBottle, encode, decode,
         decodeHeader, audit, validate, tritSum } from "./types";

// WRITE: create a bottle with a msgpack-encoded payload
const payload = new TextEncoder().encode(JSON.stringify({ result: 42 }));
const bottle = createBottle("agent", "router", "cycle.complete",
                             [-1, 0, 1] as Trit[], payload, 30);
const wireBytes = encode(bottle);

// READ: decode the envelope only (header)
const header = decodeHeader(wireBytes);
console.log(header.src, header.tgt, header.act);

// READ: decode the full bottle
const full = decode(wireBytes);
const rawPayload = atob(full.pay); // decoded msgpack bytes
```

The `uuidv7()` helper generates time-sortable IDs using `Date.now()` for the 48-bit timestamp.

## 4. Ternary Conservation Check

The conservation law states that **Σ trits (input) === Σ trits (output)** across every transformation (routing, forwarding, processing).

```typescript
// TypeScript
const inputSum = tritSum(inputBottle);   // reduce(-1|0|1 → number)
const outputSum = tritSum(outputBottle);
assert(inputSum === outputSum);

// Rust (canonical implementation)
fn audit(input: &Bottle, output: &Bottle) -> bool {
    input.trit_sum() == output.trit_sum()
}
// Strict variant returns BottleError::Conservation with expected/actual
```

A violation means the ternary charge leaked or was injected — an integrity failure. The Rust `audit_strict()` variant returns a typed error for exact diagnostics.

## 5. Crate Dependencies (from Cargo.toml)

```toml
[dependencies]
serde          = { version = "1", features = ["derive"] }    # JSON/MSGPACK (de)serialization
serde_json     = "1"                                          # Envelope JSON format
rmp-serde      = "1"                                          # MessagePack encode/decode
uuid           = { version = "1", features = ["v7", "serde"] }# UUIDv7 generation + serde support
base64         = "0.22"                                       # Base64 payload encoding
thiserror      = "2"                                          # Typed error derivation

[dev-dependencies]  # none declared
```

**Key insight:** The protocol depends only on serde-family crates + uuid + base64 — no heavy networking, async, or HTTP dependencies. This keeps it embeddable in any Rust service (edge devices, fleet nodes, CI pipelines) with a minimal footprint.

**Compliance requirement:** Any conformant implementation must preserve the envelope field semantics, the base64(msgpack) encoding pipeline, and the Σ trits conservation invariant.
