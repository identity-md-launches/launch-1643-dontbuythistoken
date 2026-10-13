# Test report

Command (run 2026-10-13, forge 1.8.4, solc 0.8.26, via-IR):

```
FOUNDRY_FUZZ_SEED=0x6db4fb9e8219718221c07e9d6a1b41d1300d50a7ad58787663b260552f351f1f forge test
forge fmt --check
forge build --sizes
```

Result: 56 tests, 56 passed, 0 failed, across three suites. `forge fmt --check` clean. All runtimes
under 24,576 bytes (PadGame 12,478; PadLiquidity 11,460; PvPPad 9,171; PadToken 3,210; KingOfThePad
2,832; PadHook 492).

| Suite | Tests | Covers |
|-------|-------|--------|
| `test/Pad.t.sol` | 18 | one-shot deployment, opcode scan and sizes, bindings one-shot, templates not initializable, closed pad reverts, openPad by owner / bad salt / stranger before 30 days / anyone after / once, deployHook access, hook rejects foreign initialize (direct and via manager), launch gating on genesis, string limits, carry pot, upkeep access |
| `test/Game.t.sol` | 28 | signup start, one per wallet, window, 200 cap, roll preconditions, split genesis vs non-genesis, curve quotes, token lock and unlock access, RNG resolution after commit+3, expiry toward zero, own-previous-roll resolution, batch of 8, bell, death, all-dead end, dead imp cannot roll, 60 min cap, ranking and triangular payout with bell share, pending rolls block finalize, finalizer fee cap, claimable fallback, ETH conservation, graduation (pool, unlock, burn excess, price), failed graduation, graduate access, upkeep-driven finalize and graduate |
| `test/King.t.sol` | 10 | min bid, whole-first-bid split, hold and 110% rule, refund in full, live-game weighting by pot with the 5-Imp filter, rejecting king refund claimable, distribute to king with token-side sale, escrow without king, burn chunk cap and 10-minute interval, burn waits for PvP, callback access, second launch graduates into its own pool |

Mocks: `MockArbSys` etched at `0x64` (settable block number, hashes only inside the 256-block
window); `MockPoolManager` (unlock accounting, hook check on initialize, full-range amounts,
constant-product swap with pool fee, fee accrual). The real v4 PoolManager was not exercised; see
`docs/AUDIT.md` item 6.

Not measured: 200-Imp finalization gas; real one-shot deployment gas (forge under-reports nested
creation deposit in tests; estimate about 9M from runtime sizes).
