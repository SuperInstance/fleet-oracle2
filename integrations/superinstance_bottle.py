#!/usr/bin/env python3
"""
superinstance_bottle.py — Python implementation of the SuperInstance Hybrid Bottle Protocol.

Wire format: JSON envelope with base64-encoded msgpack payload.
Ternary conservation: sum of trits is preserved across transformations.

Usage:
    bottle = Bottle.new("colony-games", "fleet-pulse", "game.pd.round",
                        trits=[-1, 0, 1], payload={"round": 1, "moves": [...]})
    wire = bottle.encode()       # JSON bytes
    decoded = Bottle.decode(wire)
    decoded.decode_payload()     # -> original payload dict
    bottle.validate()            # TTL check
    audit(in_bottle, out_bottle) # conservation check
"""

import json
import base64
import uuid
import struct
import time
from typing import Any, Optional


# ─── Trit type ─────────────────────────────────────────────────────────────────
Trit = int  # -1, 0, or +1


# ─── Errors ────────────────────────────────────────────────────────────────────
class BottleError(Exception):
    def __init__(self, message: str):
        super().__init__(message)


class ConservationError(BottleError):
    def __init__(self, expected: int, actual: int):
        super().__init__(f"Conservation violation: expected sum {expected}, got {actual}")
        self.expected = expected
        self.actual = actual


class ValidationError(BottleError):
    def __init__(self, reason: str):
        super().__init__(f"Validation failed: {reason}")


# ─── UUIDv7 Generator (pure Python) ──────────────────────────────────────────
def uuidv7() -> str:
    """Generate a time-sortable UUIDv7 string.

    Format: 48-bit unix_ms + 4-bit version (7) + 12-bit random_a
           + 2-bit variant (10) + 62-bit random_b
    """
    unix_ms = int(time.time() * 1000)
    rand_a = (0x7000 | (uuid.uuid4().fields[0] & 0x0fff))  # ver 7 in top 4 bits
    rand_b = uuid.uuid4().fields[0]
    rand_c = uuid.uuid4().fields[0]

    time_hex = f"{unix_ms:012x}"
    rand_a_hex = f"{rand_a:04x}"
    rand_b_hex = f"{rand_b:04x}"
    rand_c_hex = f"{rand_c & 0x3fffffff | 0x80000000:08x}"

    return f"{time_hex[:8]}-{time_hex[8:12]}-{rand_a_hex}-{rand_b_hex}-{rand_c_hex[:4]}{rand_c_hex[4:]}"


def uuidv7_to_timestamp(uuid_str: str) -> int:
    """Extract unix_ms timestamp from a UUIDv7 string."""
    hex_str = uuid_str.replace("-", "")[:12]
    return int(hex_str, 16)


# ─── BottleHeader — envelope only ─────────────────────────────────────────────
class BottleHeader:
    """Lightweight view of the envelope (no payload)."""

    def __init__(self, id: str, ver: int, src: str, tgt: str, act: str,
                 trits: list[Trit], enc: str, ttl: int):
        self.id = id
        self.ver = ver
        self.src = src
        self.tgt = tgt
        self.act = act
        self.trits = trits
        self.enc = enc
        self.ttl = ttl

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "ver": self.ver,
            "src": self.src,
            "tgt": self.tgt,
            "act": self.act,
            "trits": self.trits,
            "enc": self.enc,
            "ttl": self.ttl,
        }


# ─── Bottle — full wire object ────────────────────────────────────────────────
class Bottle:
    """A SuperInstance bottle: JSON envelope with opaque msgpack payload."""

    def __init__(self, id: str, ver: int, src: str, tgt: str, act: str,
                 trits: list[Trit], enc: str, pay: str, ttl: int):
        self.id = id
        self.ver = ver
        self.src = src
        self.tgt = tgt
        self.act = act
        self.trits = trits
        self.enc = enc
        self.pay = pay  # base64-encoded msgpack payload
        self.ttl = ttl

    # ─── Constructors ─────────────────────────────────────────────────────

    @classmethod
    def new(cls, src: str, tgt: str, act: str, trits: list[Trit],
            payload: Any, ttl: int = 30) -> "Bottle":
        """Create a new bottle with a msgpack-encoded payload."""
        import msgpack
        encoded = msgpack.packb(payload)
        return cls(
            id=uuidv7(),
            ver=1,
            src=src,
            tgt=tgt,
            act=act,
            trits=trits,
            enc="msgpack",
            pay=base64.b64encode(encoded).decode("utf-8"),
            ttl=ttl,
        )

    @classmethod
    def new_empty(cls, src: str, tgt: str, act: str,
                  trits: list[Trit], ttl: int = 30) -> "Bottle":
        """Create a bottle with no structured payload."""
        import msgpack
        encoded = msgpack.packb(None)
        return cls(
            id=uuidv7(),
            ver=1,
            src=src,
            tgt=tgt,
            act=act,
            trits=trits,
            enc="msgpack",
            pay=base64.b64encode(encoded).decode("utf-8"),
            ttl=ttl,
        )

    # ─── Wire format ──────────────────────────────────────────────────────

    def encode(self) -> bytes:
        """Encode this bottle to JSON wire format."""
        return json.dumps(self.to_dict(), ensure_ascii=False).encode("utf-8")

    @classmethod
    def decode(cls, data: bytes) -> "Bottle":
        """Decode a bottle from JSON wire format bytes."""
        obj = json.loads(data.decode("utf-8"))
        return cls.from_dict(obj)

    @classmethod
    def decode_header(cls, data: bytes) -> BottleHeader:
        """Parse just the envelope (header), ignoring payload."""
        obj = json.loads(data.decode("utf-8"))
        obj.pop("pay", None)
        return BottleHeader(**{
            k: obj[k] for k in ["id", "ver", "src", "tgt", "act", "trits", "enc", "ttl"]
        })

    # ─── Payload ──────────────────────────────────────────────────────────

    def decode_payload(self) -> Any:
        """Decode the msgpack payload to a Python object."""
        import msgpack
        raw_bytes = base64.b64decode(self.pay)
        return msgpack.unpackb(raw_bytes)

    # ─── Validation ───────────────────────────────────────────────────────

    def validate(self) -> None:
        """Validate the bottle: TTL, version, trit validity."""
        now_ms = int(time.time() * 1000)
        created_ms = uuidv7_to_timestamp(self.id)
        if now_ms > created_ms + self.ttl * 1000:
            raise ValidationError(f"TTL expired for bottle {self.id}")

        if self.ver != 1:
            raise ValidationError(f"Unsupported envelope version: {self.ver}")

        for t in self.trits:
            if t not in (-1, 0, 1):
                raise ValidationError(
                    f"Invalid trit value {t}: must be -1, 0, or +1"
                )

    def trit_sum(self) -> int:
        """Compute the ternary sum of this bottle's trits."""
        return sum(self.trits)

    # ─── Serialization helpers ────────────────────────────────────────────

    def to_dict(self) -> dict:
        return self.header().to_dict() | {"pay": self.pay}

    @classmethod
    def from_dict(cls, obj: dict) -> "Bottle":
        return cls(
            id=obj["id"],
            ver=obj["ver"],
            src=obj["src"],
            tgt=obj["tgt"],
            act=obj["act"],
            trits=obj["trits"],
            enc=obj["enc"],
            pay=obj["pay"],
            ttl=obj["ttl"],
        )

    def header(self) -> BottleHeader:
        return BottleHeader(
            id=self.id, ver=self.ver, src=self.src, tgt=self.tgt,
            act=self.act, trits=self.trits, enc=self.enc, ttl=self.ttl,
        )

    def __repr__(self) -> str:
        return (
            f"Bottle(id={self.id[:8]}, src={self.src}, tgt={self.tgt}, "
            f"act={self.act}, trits={self.trits}, ttl={self.ttl})"
        )


# ─── Conservation Audit ──────────────────────────────────────────────────────
def audit(input_bottle: Bottle, output_bottle: Bottle) -> bool:
    """Returns True if ternary charge is conserved between input and output."""
    return input_bottle.trit_sum() == output_bottle.trit_sum()


def audit_strict(input_bottle: Bottle, output_bottle: Bottle) -> None:
    """Raises ConservationError if conservation is violated."""
    in_sum = input_bottle.trit_sum()
    out_sum = output_bottle.trit_sum()
    if in_sum != out_sum:
        raise ConservationError(in_sum, out_sum)


# ─── Quick test ──────────────────────────────────────────────────────────────
if __name__ == "__main__":
    # Test round-trip
    bottle = Bottle.new(
        src="colony-games",
        tgt="fleet-pulse",
        act="game.pd.round",
        trits=[-1, 0, 1, -1],
        payload={
            "round": 42,
            "players": 13,
            "moves": [("cooperate", "defect"), ("defect", "defect")],
        },
        ttl=60,
    )
    print(f"Original: {bottle}")
    print(f"  Payload: {bottle.decode_payload()}")

    # Encode/decode round-trip
    wire = bottle.encode()
    decoded = Bottle.decode(wire)
    print(f"Decoded: {decoded}")
    print(f"  Payload OK: {decoded.decode_payload() == bottle.decode_payload()}")

    # Header-only
    header = Bottle.decode_header(wire)
    print(f"Header: act={header.act}, src={header.src}")

    # Validation
    bottle.validate()
    print(f"Valid: OK")

    # Conservation
    out = Bottle.new(
        src="fleet-pulse", tgt="colony-games",
        act="game.pd.ack",
        trits=[-1, 0, 1, -1],  # Same sum = conserved
        payload={"status": "received", "round": 42},
        ttl=30,
    )
    print(f"Conservation: {audit(bottle, out)}")

    # Conservation violation
    bad = Bottle.new(
        src="fleet-pulse", tgt="colony-games",
        act="game.pd.ack",
        trits=[0, 0, 0, 0],  # Different sum = violation
        payload={"status": "bad"},
        ttl=30,
    )
    try:
        audit_strict(bottle, bad)
        print("ERROR: should have raised")
    except ConservationError as e:
        print(f"Conservation violation caught: {e}")

    print("\n✅ Python protocol client works")
