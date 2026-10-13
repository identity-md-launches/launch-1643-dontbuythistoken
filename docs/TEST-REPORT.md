# Test report

Command (run 2026-10-13, revision 2, forge 1.8.4, solc 0.8.26, via-IR):

```
FOUNDRY_FUZZ_SEED=0x6db4fb9e8219718221c07e9d6a1b41d1300d50a7ad58787663b260552f351f1f forge test
forge fmt --check
forge build --sizes
```

Result: 70 tests, 70 passed, 0 failed, across three suites. `forge fmt --check` clean. All runtimes
under 24,576 bytes (PadGame 13,619; PadLiquidity 12,392; PvPPad 11,569; PadToken 3,210; KingOfThePad
2,838; PadHook 492). The four reviewer proofs (`Proof_85d8d318f724`, `Proof_66c81d1d42c9`,
`Proof_5832a3712adf`, `Proof_f73869284b89`) were copied under `test/scratch/` and pass on this tree;
they failed on the previous one.

| Suite | Tests | Covers |
|-------|-------|--------|
| `test/Pad.t.sol` | 20 | one-shot deployment, opcode scan and sizes, bindings one-shot, templates not initializable, closed pad reverts, openPad by owner / bad salt / stranger before 30 days / anyone after / once, deployHook access, hook rejects foreign initialize (direct and via manager), launch gating on genesis, failed genesis restarted through `launch()` and `restartGenesis()` up to a graduated second PvP with king and burn on its pool, restart refused while genesis waits or plays, string limits, carry pot, upkeep access |
| `test/Game.t.sol` | 36 | signup start, one per wallet, window, 200 cap, roll preconditions, split genesis vs non-genesis, curve quotes, token lock and unlock access, RNG resolution after commit+3, expiry toward zero, own-previous-roll resolution, batch of 8, bell, death, all-dead end, dead imp cannot roll, 60 min cap, ranking and triangular payout with bell share, pending rolls block finalize, finalizer fee cap and fee from roll income only, `fundPot` pad-only, funded pot returned with fewer than five living, 3x release cap with five living, roll after own bell reverts, dead Imp cannot ring, commit-order tie-break, 200 living Imps finalize gas, claimable fallback, ETH conservation, graduation (pool, unlock, burn excess, price), failed graduation, graduate access, upkeep-driven finalize and graduate |
| `test/King.t.sol` | 14 | min bid, whole-first-bid split, hold and 110% rule, refund in full, live-game weighting by roll-earned pot with the 5-Imp filter, rejecting king refund claimable, distribute to king with token-side sale, escrow without king, burn chunk cap and 10-minute interval on a deep pool, burn chunk partial fill at the 1% price limit on a thin pool, self-sandwich of a burn chunk does not pay, finalizer fee reaches the bidder through `takeCrown`, `upkeepFor` accepts the king contract, burn waits for PvP, callback access, second launch graduates into its own pool |

Measured: finalize with 200 living Imps in worst-case order 3,752,025 gas (the first version's
insertion sort cost 21.8M); one-shot deployment under the 13M target (`test_deployGasUnderBudget`).

Mocks: `MockArbSys` etched at `0x64` (settable block number, hashes only inside the 256-block
window); `MockPoolManager` (unlock accounting, hook check on initialize, full-range amounts,
constant-product swap with pool fee and partial fill at the sqrt-price limit, live sqrt price,
`extsload` of slot0 at the v4 StateLibrary location, fee accrual, a `fatten` helper to deepen a
pool). The real v4 PoolManager was not exercised; see `docs/AUDIT.md` items 6 and 8.
