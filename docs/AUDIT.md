# PvP Pad: self-review and trust model

This is the builder's own review, not an independent audit. Work holding other people's funds
needs a separate adversarial review before release.

## Privileges

| Who | Power | Notes |
|-----|-------|-------|
| Owner / dev (`0x5b95…0d06`) | `openPad(salt)` before day 30; receives 25% of king extras | Cannot pause, upgrade, sweep, mint or change fees. After 30 days anyone can open. |
| Anyone | mint, roll, poke, finalize, graduate, launch (after PvP), restartGenesis (only after a failed PvP), takeCrown, distribute, burnChunk, claim | All permissionless, all bounded. |
| PvPPad (contract) | only caller of `PadGame.fundPot` | Carry pot at creation and the king's games share; nobody can donate to a pot. |
| Factory / IMD | none | No `msg.sender` / `tx.origin` ownership anywhere. |
| PadLiquidity | Only sender allowed by `PadHook.beforeInitialize`; may unlock tokens; owns all LP forever | No withdrawal path for LP exists. |

## Findings and accepted risks

1. **On-chain randomness.** Dice use ArbSys block hashes of the three L2 blocks after the commit
   block. On Arbitrum-stack chains the sequencer orders transactions and produces blocks, so a
   colluding sequencer could in principle bias outcomes. There is no player secret, by design, so
   players cannot grief by withholding. The 60 s cooldown plus 8-roll resolution batch keeps the
   pending queue short; past the 256-block window a roll expires and moves the Imp 4 toward 0.
   Accepted per brief; documented here.
2. **Finalization gas.** `_finalize` packs one sort key per living Imp (|height|, commit block, roll
   id, index) and heap-sorts them in memory, then pushes up to 100 payments at 30k gas each. The
   worst case, 200 living Imps in reverse rank order, measured 3,752,025 gas
   (`test_finalizeWith200LivingImpsStaysUnderFiveMillionGas`). The first version used an insertion
   sort that re-read storage in the comparator and cost 21.8M gas in that case, which upkeep could
   never afford (revision finding). A finalize that still runs out of gas inside upkeep is simply
   skipped there and `finalize()` can be called directly with more gas.
3. **Upkeep try/catch.** Graduation, distribution and burns run inside try/catch during upkeep so a
   PoolManager revert never blocks mints or rolls. A persistently reverting graduation would leave a
   game finalized but ungraduated; `graduate()` can still be called directly and will surface the
   revert reason.
4. **Genesis failure is recoverable.** The first mint on the genesis game is free and permissionless,
   so a stranger can start its clock; if nobody rolls, the game ends with no ETH, is marked failed and
   its 1e9 PVP burned. In the first version that closed the pad forever (revision finding). Now
   `PvPPad.genesisId` names the current genesis: when it has failed, anyone can call
   `restartGenesis()` and `launch()` does the same instead of reverting (it relaunches PvP and
   returns the new genesis id; the requested launch is not created). Launches, the king and the burn
   keep waiting until a PvP launch has graduated; the burn buys the token of the graduated genesis.
   A failed genesis can be griefed again at the cost of gas only, but nothing is lost: the pot of a
   game with no roll is zero and the carry pot is untouched.
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
8. **Price-impact cap on protocol swaps.** Burn buys (max 0.02 ETH per 10 minutes) and fee sales
   (max 2M tokens per collection) run inside upkeep, which anyone can trigger in the same transaction
   as their own swaps, so a self-sandwich needs no mempool race. Each protocol swap now carries a
   sqrt-price limit `IMPACT_BPS` = 0.5% from the pre-swap spot (about 1% in price, read from the
   PoolManager's slot0 through `extsload`); v4 fills only up to the limit and the unfilled ETH or
   tokens stay for the next chunk. An attacker who pushes the price first gains at most about 1% of
   the position they hold through the chunk and pays the 1% pool fee twice on it, so the sandwich
   cannot pay (`test_sandwichOnBurnChunkDoesNotPay`). The cost is slower burns in a thin PvP pool:
   the pool is as deep as the genesis raise, and a chunk fills only what a 1% move allows
   (`test_burnChunkStopsAtOnePercentPriceMoveAndKeepsTheRest`). The limit is relative to the current
   spot, so it bounds damage per chunk rather than detecting manipulation; a thin PvP pool remains a
   known weakness of the design.
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

13. **Funded pots (carry pot, king share) are escrowed inside the game.** `PadGame.fundedPot`
    tracks ETH the pad put into a pot (carry at creation, king's 50% games share) apart from what
    rolls earned. At the end it is paid out only if at least `FUNDED_MIN_LIVING` (5) Imps are living,
    and never more than `FUNDED_RELEASE_MULTIPLE` (3) times the roll-earned pot; whatever is not
    released returns to the carry pot (`FundedReturned`) and reaches the next launch. The finalizer
    fee (0.5%, max 0.005 ETH) is paid from roll income only, so no fee can be farmed from funded
    ETH. The king's weighting uses the roll-earned pot and `fundPot` is pad-only, so a pot cannot be
    steered by donations. Why the 3x cap: a sybil with five wallets who rolls X ETH gets back its roll
    pot (8%), at most 3x that from funded ETH (24%) and at most about half of the curve ETH by dumping
    its tokens into the graduated pool (45%), about 77% of X: capturing funded ETH costs more than it
    returns. The residual is that free Imps still make a launch "live" for the king split (five
    mints, no EOA check); that share is then capped by the game's own roll income and otherwise
    returns to the carry. Revision findings 66c81d1d and 5832a371.
14. **Upkeep callers and fees.** `KingOfThePad.takeCrown` runs `pad.upkeepFor(msg.sender)`, so a
    finalizer fee paid by that upkeep goes to the bidder, not to the king contract (which cannot
    claim). `upkeepFor` accepts games and the king contract only. Revision finding f7386928.
15. **Roll after the bell.** `roll()` resolves the Imp's previous roll first; if that resolution rings
    the bell the call now reverts `game over` instead of recording a roll after the end.
16. **Dead Imps and the bell.** A roll resolved after its Imp has died (quiet chain, no L2 blocks)
    still moves the height but cannot ring the bell or earn the 20% share.
17. **Tie-break.** `heightReachedAt` is the commit L2 block of the roll that reached the height, with
    the roll index as a second key, so ties follow commit order, not who resolved first.
18. **Receive guard.** `PadLiquidity.receive()` accepts ETH only from the PoolManager; all other ETH
    enters through `fundBurn` or `graduate` and is credited to a bucket.
19. **One-shot binders.** `bindLiquidity`, `startGenesis` and `bindKing` accept the first caller.
    They are safe only because the launch deploys the five contracts in one transaction from the
    factory; a rehearsal in separate transactions must not leave a window between them. Trust
    assumption of the deployment policy, documented, not changed.
20. **upkeepStep lock.** `upkeepStep` now sets the game's reentrancy lock while it finalizes or
    graduates, so the protection no longer rests on the 30k push gas cap alone.
21. **Dethroning and LP fees.** `distribute()` pays whoever is king at payout time, and `takeCrown`
    runs upkeep after crowning the challenger, so uncollected fees of the previous reign go to the new
    king. This follows the brief ("send all to the current king"); a king who wants the backlog calls
    `distribute(poolCount)` before being dethroned. Design note.
22. **Free mints are not EOA-checked.** Contracts can mint Imps (one per address), so 200 helper
    contracts could fill a signup in one transaction. The design asked for free records with no
    identity; the funded-pot rules above make such a game unprofitable, and the fill only locks the
    attacker's own launch. Accepted, documented.

## Edges covered by tests and known gaps

Covered: open/salt/expiry/once, hook foreign initialize (direct and through the manager), genesis
gating of launch and king, deploy gas and opcode scan, signup window and caps, roll preconditions,
split (genesis and non-genesis), curve quotes and sold-out cap, token lock and unlock, RNG
resolution timing, expiry, own-previous-roll resolution, batch of 8, bell, death, all-dead,
60-minute cap, ranking with ties and triangular weights, bell share, finalizer fee cap,
claimable fallback, ETH conservation, graduation (pool, unlock, burn excess, price), failed
graduation, upkeep-driven finalize/graduate, king bid rules, king split, live-game weighting,
refund claimable, distribute to king and escrow, burn chunk cap and interval, failed genesis
restart (via `launch` and `restartGenesis`) through to a graduated second PvP and a burn on its
pool, funded pot returned with fewer than five living, 3x release cap with five living, finalizer
fee from roll income only, `fundPot` pad-only, king share weighted by roll pot, finalizer fee to
the bidder through `takeCrown`, roll after own bell reverts, dead Imp cannot ring, commit-order
tie-break, 200 living Imps finalize gas, burn chunk partial fill at the price limit, self-sandwich
does not pay.

Gaps: no fuzz/invariant suite over many rounds; no fork test against the real PoolManager (the
`extsload` slot0 layout and partial fills at a price limit are modelled by the mock and must be
rehearsed on a fork); multi-game round-robin upkeep over more than two games is only lightly
exercised.

## Tools run

`forge build`, `forge test` (70 tests plus the four reviewer proofs run from `test/scratch/`),
`forge fmt --check`, and a bytecode scan for forbidden opcodes in the test suite. Slither/Mythril
were not available offline.
