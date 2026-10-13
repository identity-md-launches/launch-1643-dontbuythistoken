# PvP Pad: self-review and trust model

This is the builder's own review, not an independent audit. Work holding other people's funds
needs a separate adversarial review before release.

## Privileges

| Who | Power | Notes |
|-----|-------|-------|
| Owner / dev (`0x5b95…0d06`) | `openPad(salt)` before day 30; receives 25% of king extras | Cannot pause, upgrade, sweep, mint or change fees. After 30 days anyone can open. |
| Anyone | mint, roll, poke, finalize, graduate, launch (after PvP), takeCrown, distribute, burnChunk, claim | All permissionless, all bounded. |
| Factory / IMD | none | No `msg.sender` / `tx.origin` ownership anywhere. |
| PadLiquidity | Only sender allowed by `PadHook.beforeInitialize`; may unlock tokens; owns all LP forever | No withdrawal path for LP exists. |

## Findings and accepted risks

1. **On-chain randomness.** Dice use ArbSys block hashes of the three L2 blocks after the commit
   block. On Arbitrum-stack chains the sequencer orders transactions and produces blocks, so a
   colluding sequencer could in principle bias outcomes. There is no player secret, by design, so
   players cannot grief by withholding. The 60 s cooldown plus 8-roll resolution batch keeps the
   pending queue short; past the 256-block window a roll expires and moves the Imp 4 toward 0.
   Accepted per brief; documented here.
2. **Finalization gas.** `_finalize` insertion-sorts up to 200 living Imps in memory and pushes up to
   100 payments at 30k gas each. Worst case is a few million gas and may run inside another user's
   roll via upkeep. Robinhood Chain gas is cheap; pushes that fail become claimable so no payout can
   block the round.
3. **Upkeep try/catch.** Graduation, distribution and burns run inside try/catch during upkeep so a
   PoolManager revert never blocks mints or rolls. A persistently reverting graduation would leave a
   game finalized but ungraduated; `graduate()` can still be called directly and will surface the
   revert reason.
4. **Genesis failure.** If PvP raises no ETH it is marked failed and `genesisGraduated()` stays false
   forever: no further launches, no king, no burns. This follows the brief's gating literally. The
   owner should ensure PvP is played (at least one roll) before relying on the pad.
5. **Liquidity rounding.** `PadLiquidity` computes full-range liquidity with its own mulDiv and takes
   a 1 ppm haircut so the real PoolManager (which rounds amounts up) never asks for more ETH than
   sent. Any ETH dust left goes to the burn bucket; token excess goes to dEaD.
6. **Real v4 math untested here.** Tests use `MockPoolManager`, a behavioural stand-in (unlock
   accounting, hook call on initialize, full-range amounts, constant-product swap with pool fee).
   The real PoolManager's TickMath and SqrtPriceMath were not exercised offline. Before opening the
   pad, rehearse one graduation and one `distribute(1)` on a fork of Robinhood Chain against the real
   PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`. The full-range sqrt prices
   (`SQRT_MIN_FULL`, `SQRT_MAX_FULL` for ticks ±887200) were computed off-chain with exact rational
   arithmetic.
7. **Hook address.** `openPad` reverts unless `address & 0x3FFF == 0x2000`. The v4 PoolManager
   validates the same mask at `initialize`. Only PadLiquidity can initialize pools with the hook.
8. **Price manipulation of burn / distribute swaps.** Burn buys are capped at 0.02 ETH per 10
   minutes and fee sales at 2M tokens per collection, limiting sandwich value. Both are expected to
   be sandwiched at the margin; accepted.
9. **King accounting.** The king contract never holds a settled bid: the whole first bid is split,
   and each later bid refunds the previous king and splits the extra. The balance therefore equals
   the sum of claimables. Tested.
10. **Token lock bypass.** While locked, only `msg.sender == game || liquidity` may move tokens.
    Approvals do not bypass the lock (tested). The lock is per-token and only PadLiquidity can
    unlock it.
11. **Reentrancy.** Every entry point that moves ETH has a guard. Upkeep callbacks into a game that
    is already locked return immediately. Pushes have 30k gas, insufficient to re-enter any
    state-changing function meaningfully; failures become claimable.
12. **Timestamps.** Minutes/hours/days use `block.timestamp` (sequencer-controlled within protocol
    bounds). Block numbers from ArbSys are used only for the RNG window. The brief's "timing uses
    ArbSys" was read as the RNG commit window, because L2 block cadence is not a reliable clock.

## Edges covered by tests and known gaps

Covered: open/salt/expiry/once, hook foreign initialize (direct and through the manager), genesis
gating of launch and king, deploy gas and opcode scan, signup window and caps, roll preconditions,
split (genesis and non-genesis), curve quotes and sold-out cap, token lock and unlock, RNG
resolution timing, expiry, own-previous-roll resolution, batch of 8, bell, death, all-dead,
60-minute cap, ranking with ties and triangular weights, bell share, finalizer fee cap,
claimable fallback, ETH conservation, graduation (pool, unlock, burn excess, price), failed
graduation, upkeep-driven finalize/graduate, king bid rules, king split, live-game weighting,
refund claimable, distribute to king and escrow, burn chunk cap and interval.

Gaps: no fuzz/invariant suite over many rounds; no fork test against the real PoolManager; the
200-Imp finalization gas is not measured; multi-game round-robin upkeep over more than two games
is only lightly exercised.

## Tools run

`forge build`, `forge test` (56 tests), `forge fmt --check`, and a bytecode scan for forbidden
opcodes in the test suite. Slither/Mythril were not available offline.
