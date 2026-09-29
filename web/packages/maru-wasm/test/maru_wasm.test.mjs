// T03-T07: @openmaru/maru-wasm matches the Rust version and the shared echo vectors.
import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { initSync, version, echo_json, authz_enabled } from "@openmaru/maru-wasm";

const root = new URL("../../../../", import.meta.url);
const vectors = JSON.parse(
  readFileSync(new URL("crates/maru_core/tests/vectors/echo.json", root), "utf8"),
);
const cargoToml = readFileSync(new URL("Cargo.toml", root), "utf8");
const rustVersion = /\[workspace\.package\][^[]*?^version\s*=\s*"([^"]+)"/ms.exec(cargoToml)[1];

describe("@openmaru/maru-wasm", () => {
  before(() => {
    const wasm = readFileSync(new URL("../pkg/maru_wasm_bg.wasm", import.meta.url));
    initSync({ module: wasm });
  });

  it("T03-T07 version() matches the Rust version", () => {
    assert.equal(version(), rustVersion);
  });

  it("T03-T07 echo_json vectors match", () => {
    assert.ok(vectors.length > 0);
    for (const { input, output } of vectors) {
      assert.equal(echo_json(input), output, `input: ${JSON.stringify(input)}`);
    }
  });

  it("T03-T07 invalid JSON throws an invalid JSON error", () => {
    for (const input of ["", "{", "[1,]", '{"a":1} x']) {
      assert.throws(() => echo_json(input), /invalid JSON/);
    }
  });

  it("T03-T09 the WASM build has the authz feature disabled", () => {
    assert.equal(authz_enabled(), false);
  });
});
