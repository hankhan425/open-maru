#!/usr/bin/env python3
"""Independent implementation of the ledger hash chain (SPEC-03 §7). Standard library only.

Generates apps/server/test/fixtures/ledger_vectors.json: a short ledger history (a budget
grant, a pending hold and its partial post, a hold voided by the expiry sweeper, and a
linked reset + grant), the encoded bytes and expected hash of every transfer, and UUIDv5
vectors in the openmaru namespace. Elixir (G01-T15) and the Rust CLI (A04 `ledger verify`)
check their encodings against this file, so it must be produced by this script, not by
the code under test.

Usage:
  scripts/ledger_vector.py            print the vectors JSON to stdout
  scripts/ledger_vector.py --write    write the fixture file
  scripts/ledger_vector.py --check    exit 1 if the committed fixture differs from the output

JSON conventions: 64-bit integers (amounts, user_data_64, timestamps, seq) are decimal
strings so JavaScript readers stay exact; u32 fields are numbers; bytes are lowercase hex;
missing references are null.
"""

import argparse
import datetime
import hashlib
import json
import os
import struct
import sys
import uuid

FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "apps", "server", "test", "fixtures", "ledger_vectors.json",
)

# SPEC-03 §5: uuidv5(x) is UUIDv5 in the openmaru namespace.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://openmaru.org/")

I64_MAX = 2**63 - 1
GENESIS = bytes(32)

# Transfer flag bits (SPEC-03 §2).
FLAGS = {
    "linked": 1 << 0,
    "pending": 1 << 1,
    "post_pending": 1 << 2,
    "void_pending": 1 << 3,
    "balancing_debit": 1 << 4,
    "balancing_credit": 1 << 5,
}

# Account flag bits.
DMNEC = 1 << 0


def uuidv5(name):
    return str(uuid.uuid5(NAMESPACE, name))


def uuid_bytes(value):
    return bytes(16) if value is None else uuid.UUID(value).bytes


def flag_bits(names):
    bits = 0
    for name in names:
        bits |= FLAGS[name]
    return bits


def encode(t):
    """SPEC-03 §7: fixed-width big-endian fields in a fixed order (136 bytes)."""
    return b"".join(
        [
            uuid_bytes(t["id"]),
            uuid_bytes(t["debit_account_id"]),
            uuid_bytes(t["credit_account_id"]),
            struct.pack(">q", t["amount"]),
            struct.pack(">q", t["requested_amount"]),
            uuid_bytes(t["pending_id"]),
            struct.pack(">IIII", t["flags"], t["timeout_secs"], t["ledger"], t["code"]),
            uuid_bytes(t["user_data_128"]),
            struct.pack(">q", 0 if t["user_data_64"] is None else t["user_data_64"]),
            struct.pack(">q", t["timestamp"]),
            struct.pack(">q", t["seq"]),
        ]
    )


def chain(transfers):
    """Assigns seq from 1 and links each transfer's hash to the previous one."""
    prev = GENESIS
    out = []
    for seq, t in enumerate(transfers, start=1):
        row = dict(t, seq=seq)
        encoded = encode(row)
        digest = hashlib.sha256(prev + encoded).digest()
        out.append((row, encoded, prev, digest))
        prev = digest
    return out


def micros(dt):
    delta = dt - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    return (delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def build():
    t0 = datetime.datetime(2026, 10, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)

    def at(seconds):
        return t0 + datetime.timedelta(seconds=seconds)

    source = uuidv5("system:allowance_source")
    sink = uuidv5("system:allowance_sink")
    mandate = "0199a0b2-7c00-7000-8000-000000000001"
    budget = "0199a0b2-7c00-7000-8000-0000000000b1"
    spend_1 = "0199a0b2-7c00-7000-8000-00000000005a"
    spend_2 = "0199a0b2-7c00-7000-8000-00000000005b"
    hold_1 = "0199a0b2-7c00-7000-8000-0000000000f1"
    post_1 = "0199a0b2-7c00-7000-8000-0000000000f2"
    hold_2 = "0199a0b2-7c00-7000-8000-0000000000f3"
    october, november = 1202610, 1202611

    accounts = [
        {"id": source, "key": "system:allowance_source", "ledger": 1, "code": 600, "flags": []},
        {"id": sink, "key": "system:allowance_sink", "ledger": 1, "code": 610, "flags": []},
        {
            "id": budget,
            "key": "mandate:%s:budget:llm" % mandate,
            "ledger": 1,
            "code": 500,
            "flags": ["debits_must_not_exceed_credits"],
        },
    ]

    def row(**fields):
        base = {
            "pending_id": None,
            "flags": 0,
            "timeout_secs": 0,
            "ledger": 1,
            "user_data_128": None,
            "user_data_64": None,
        }
        base.update(fields)
        base.setdefault("requested_amount", base["amount"])
        return base

    grant_oct = uuidv5("grant:%s:llm:%d" % (mandate, october))
    expire_2 = uuidv5("expire:%s" % hold_2)
    reset_nov = uuidv5("reset:%s:llm:%d" % (mandate, november))
    grant_nov = uuidv5("grant:%s:llm:%d" % (mandate, november))

    # Each step is one create_transfers call (or one sweeper run) with the Clock at `clock`.
    # Expected rows follow in chain order; timestamps are the clock, +1 µs within a batch.
    steps = [
        (at(1), [{"id": grant_oct, "debit_account_id": source, "credit_account_id": budget,
                  "amount": 50000000, "flags": [], "code": 30, "user_data_64": october}]),
        (at(2), [{"id": hold_1, "debit_account_id": budget, "credit_account_id": sink,
                  "amount": 12500000, "flags": ["pending"], "timeout_secs": 900, "code": 31,
                  "user_data_128": spend_1, "user_data_64": october}]),
        # Partial post: accounts, code and user data come from the pending transfer.
        (at(3), [{"id": post_1, "pending_id": hold_1, "amount": 10000000,
                  "flags": ["post_pending"]}]),
        (at(4), [{"id": hold_2, "debit_account_id": budget, "credit_account_id": sink,
                  "amount": 3000000, "flags": ["pending"], "timeout_secs": 120, "code": 31,
                  "user_data_128": spend_2, "user_data_64": october}]),
        # The sweeper voids hold_2 once its 120 s timeout has passed.
        (at(154), "expire"),
        # Period reset (balancing, requested = i64 max) linked with the next grant.
        (at(200), [{"id": reset_nov, "debit_account_id": budget, "credit_account_id": sink,
                    "amount": I64_MAX, "flags": ["linked", "balancing_debit"], "code": 32,
                    "user_data_64": november},
                   {"id": grant_nov, "debit_account_id": source, "credit_account_id": budget,
                    "amount": 50000000, "flags": [], "code": 30, "user_data_64": november}]),
    ]

    rows = [
        row(id=grant_oct, debit_account_id=source, credit_account_id=budget, amount=50000000,
            code=30, user_data_64=october, timestamp=micros(at(1))),
        row(id=hold_1, debit_account_id=budget, credit_account_id=sink, amount=12500000,
            flags=FLAGS["pending"], timeout_secs=900, code=31, user_data_128=spend_1,
            user_data_64=october, timestamp=micros(at(2))),
        row(id=post_1, debit_account_id=budget, credit_account_id=sink, amount=10000000,
            pending_id=hold_1, flags=FLAGS["post_pending"], code=31, user_data_128=spend_1,
            user_data_64=october, timestamp=micros(at(3))),
        row(id=hold_2, debit_account_id=budget, credit_account_id=sink, amount=3000000,
            flags=FLAGS["pending"], timeout_secs=120, code=31, user_data_128=spend_2,
            user_data_64=october, timestamp=micros(at(4))),
        row(id=expire_2, debit_account_id=budget, credit_account_id=sink, amount=3000000,
            pending_id=hold_2, flags=FLAGS["void_pending"], code=31, user_data_128=spend_2,
            user_data_64=-1, timestamp=micros(at(154))),
        # Available = 50 granted - 10 posted - 0 pending = 40 USD.
        row(id=reset_nov, debit_account_id=budget, credit_account_id=sink, amount=40000000,
            requested_amount=I64_MAX, flags=FLAGS["linked"] | FLAGS["balancing_debit"],
            code=32, user_data_64=november, timestamp=micros(at(200))),
        row(id=grant_nov, debit_account_id=source, credit_account_id=budget, amount=50000000,
            code=30, user_data_64=november, timestamp=micros(at(200)) + 1),
    ]

    transfers = []
    for t, encoded, prev, digest in chain(rows):
        transfers.append(
            {
                "seq": str(t["seq"]),
                "id": t["id"],
                "debit_account_id": t["debit_account_id"],
                "credit_account_id": t["credit_account_id"],
                "amount": str(t["amount"]),
                "requested_amount": str(t["requested_amount"]),
                "pending_id": t["pending_id"],
                "flags": t["flags"],
                "timeout_secs": t["timeout_secs"],
                "ledger": t["ledger"],
                "code": t["code"],
                "user_data_128": t["user_data_128"],
                "user_data_64": None if t["user_data_64"] is None else str(t["user_data_64"]),
                "timestamp": str(t["timestamp"]),
                "encoded": encoded.hex(),
                "prev_hash": prev.hex(),
                "hash": digest.hex(),
            }
        )

    def input_json(t):
        out = dict(t)
        if out.get("amount") is not None:
            out["amount"] = str(out["amount"])
        if out.get("user_data_64") is not None:
            out["user_data_64"] = str(out["user_data_64"])
        return out

    step_json = []
    for clock, action in steps:
        if action == "expire":
            step_json.append({"clock": iso(clock), "expire": True})
        else:
            step_json.append({"clock": iso(clock), "create_transfers": [input_json(t) for t in action]})

    names = [
        "system:allowance_source",
        "system:allowance_sink",
        "expire:%s" % hold_2,
        "grant:%s:llm:%d" % (mandate, october),
        "reset:%s:llm:%d" % (mandate, november),
        "",
    ]

    return {
        "about": "SPEC-03 §7 hash chain vectors. Generated by scripts/ledger_vector.py; do not edit.",
        "namespace": str(NAMESPACE),
        "uuidv5": [{"name": n, "uuid": uuidv5(n)} for n in names],
        "genesis_prev_hash": GENESIS.hex(),
        "accounts": accounts,
        "steps": step_json,
        "transfers": transfers,
    }


def render():
    return json.dumps(build(), indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--write", action="store_true", help="write the fixture file")
    group.add_argument("--check", action="store_true", help="fail if the fixture is stale")
    args = parser.parse_args()

    output = render()
    if args.write:
        with open(FIXTURE, "w") as f:
            f.write(output)
    elif args.check:
        try:
            with open(FIXTURE) as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != output:
            sys.stderr.write("%s is stale; run scripts/ledger_vector.py --write\n" % FIXTURE)
            return 1
        print("ledger vectors ok")
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
