# PvP Pad

Launchpad on Robinhood Chain (chain id 4663) where every launch is a fast Spireth dice game, all
payments in ETH. Contracts only: this deployment mints **no token**. Every token, including the
genesis "Pepes Value Pepes" (PVP), is created later by the pad itself as an EIP-1167 clone.

> **Legal review before public launch.** This is a game of chance with real ETH stakes, an auction
> and token issuance. Get a legal review for the jurisdictions you operate in before opening the pad
> or publishing a site. Nothing here is legal advice. Tests passing is not a security audit: see
> `docs/AUDIT.md`.

## Contracts (deploy order)

| # | Contract | Constructor args | Role |
|---|----------|------------------|------|
| 0 | `PadToken` | none | ERC-20 template, cloned per launch (1e9 supply, 18 decimals, locked until graduation) |
| 1 | `PadGame` | none | Template: bonding curve + Spireth game, cloned per launch |
| 2 | `PvPPad` | `$owner`, `$contract:PadToken`, `$contract:PadGame` | Registry, clone factory, carry pot, open switch, bounded upkeep |
| 3 | `PadLiquidity` | `0x8366a39cc670b4001a1121b8f6a443a643e40951` (v4 PoolManager), `$contract:PvPPad` | Graduation into Uniswap v4, LP owned forever, fee collection for the king, PvP burn |
| 4 | `KingOfThePad` | `$contract:PvPPad`, `$contract:PadLiquidity`, `0x5b95a971b4583a5f011e9da082acdd679b870d06` (dev) | Crown auction; its constructor binds everything and calls `PvPPad.startGenesis()` |

`$owner` and dev are both `0x5b95a971b4583a5f011e9da082acdd679b870d06` (immutable). Nothing is owned
by the factory or by IMD; `PvPPad.owner()` and `KingOfThePad.owner()` both return the dev.

`PadHook` is **not** in the manifest. `openPad(salt)` CREATE2-deploys it from `PadLiquidity`.

Constructors are nonpayable, call only earlier manifest contracts (one-shot bindings) and never
ArbSys or the PoolManager. The last constructor creates launch #1 (two clones + initialize).
Estimated one-shot deployment of all five, including genesis, is about 9M gas: 39,151 runtime bytes
x 200 gas deposit (7.83M) plus creation overhead and the two genesis clones. Note that forge's in-test
metering of nested `new` (test `test_deployGasUnderBudget`) under-reports deposit cost, so the
final number comes from the launch simulation (target < 13M, hard cap 16,777,216). Every runtime is under 24,576 bytes
and contains no DELEGATECALL / CALLCODE / SELFDESTRUCT (clones are created at run time by the pad).

## After launch (owner's checklist)

1. **Mine the salt.** Read `PadLiquidity.hookInitCodeHash()` and the `PadLiquidity` address. Find a
   `salt` such that `address(uint160(uint256(keccak256(0xff ++ padLiquidity ++ salt ++ initCodeHash))))`
   has `address & 0x3FFF == 0x2000` (exactly the v4 `BEFORE_INITIALIZE_FLAG`). `PadLiquidity.hookAddressFor(salt)`
   predicts it on chain. About 1 in 16,384 salts match; the test helper `mineSalt()` in
   `test/Base.t.sol` shows the loop.
2. **Open the pad.** Call `PvPPad.openPad(salt)` from the owner. Anyone may call it 30 days after
   deployment (`openDeadline()`). It can only succeed once, cannot be undone and grants nothing else.
   Until then `mint`, `roll`, `launch` and `takeCrown` revert.
3. There are no other settings. Fees, timings and sizes are constants (below).

## Rules implemented

- **Open switch.** `openPad(salt)` by owner, or anyone after 30 days; once; deploys `PadHook` and
  reverts with `hook flags` unless the address has exactly the beforeInitialize flag.
- **Launch.** `launch(name<=32, ticker<=10, imageURL<=200)` by anyone after PvP graduates. 1e9
  supply minted to the game clone; transfers locked until graduation except by the game and
  `PadLiquidity`; unlocked inside the graduation transaction.
- **Curve.** Virtual constant product, 1 ETH and 1e9 tokens virtual, 800M on the curve (sold out at
  exactly 4 ETH), 200M reserved for LP. Only rolls buy, no sells. Once sold out, the roll's 90% goes
  to the pot.
- **Game.** First mint starts a 10-minute signup (free, 1 Imp per wallet, 200 max, records not
  NFTs). Then play until the bell, all dead, or 60 minutes after the first mint. Roll = 0.002 ETH,
  60 s cooldown: 90% curve buy (tokens to roller), 8% pot, 2% burn bucket (genesis: pot). Dice:
  `rand % 8` maps to -4..-1 / +1..+4. Height clamps at ±50; reaching it rings the bell and ends the
  game. Death: 10 minutes without a roll (from play start if never rolled).
- **RNG.** Each roll stores its commit L2 block from ArbSys (0x64) `arbBlockNumber()`. Outcome =
  `keccak(game, imp, nonce, arbBlockHash(commit+1), (commit+2), (commit+3))`. Anyone resolves; every
  mint, roll and poke resolves up to 8 oldest pending rolls; an Imp's roll resolves its previous
  one. Unresolved past the 256-block window: |height| moves 4 toward 0.
- **End.** Living Imps ranked by |height| desc, earlier `heightReachedAt` wins ties; top
  `ceil(living/2)` split 80% of the pot with triangular weights (`paid - rank`); bell ringer 20% (no
  bell: all to ranks; none living: carry pot for the next launch). Finalizer gets 0.5% of the pot,
  max 0.005 ETH.
- **Graduation.** Permissionless after finalization: curve ETH + remaining tokens into a v4 pool
  (native ETH / token, fee 10000, tickSpacing 200, hooks = PadHook) initialized at the final curve
  price, full range (ticks ±887200), owned forever by `PadLiquidity`; excess tokens to `0x…dEaD`.
  No ETH raised: all tokens burned, launch marked failed.
- **Genesis.** Launch #1 "Pepes Value Pepes" (PVP) is created in the last constructor and waits for
  its first mint. Its 2% burn share goes to its own pot. Other launches, the king and the burn wait
  until PvP graduates. If genesis fails (no ETH raised) the pad stays closed to new launches: that is
  the brief's gating and a known operational risk (see AUDIT).
- **Burn.** Burn-bucket ETH waits in `PadLiquidity`; after PvP graduates anyone or upkeep buys PVP
  (max 0.02 ETH per buy, one buy per 10 minutes) straight to `0x…dEaD`.
- **King.** `takeCrown()` payable: first bid ≥ 0.01 ETH, then ≥ 110% of the current bid and only
  after the king held 1 hour. Old king refunded in full at once (push, claimable on failure). Extra
  (new − old; the whole first bid): 50% to pots of live games with ≥ 5 Imps among the last 10
  launches, weighted by pot (none: carry pot), 25% burn bucket, 25% dev. `distribute(n)`: collect LP
  fees from the next n pools round-robin, sell the token side (chunk-capped), send all to the king
  (escrowed while there is no king).
- **Upkeep.** Every state-changing call runs bounded upkeep: resolve ≤ 8 rolls, one lifecycle step
  (end / finalize / graduate) on the latest game and one older game round-robin, `distribute(2)`,
  one burn chunk. External steps are wrapped in try/catch so upkeep never blocks a user action.
  `poke(game)` is public.
- **Safety.** ETH pushes are gas-capped (30k) with claimable fallback (`claim()` on each contract);
  reentrancy guards; checks-effects-interactions; bounded loops (200 Imps, 8 rolls, 10 games, n
  pools); internal accounting; `transferFrom` only spends the caller's allowance; v4 only via
  `PoolManager.unlock` with the contract's own funds.

## Named constants (choices the brief left open)

| Constant | Value | Where |
|----------|-------|-------|
| `SELL_CHUNK` | 2,000,000 tokens per fee collection | PadLiquidity |
| `PadLib.PUSH_GAS` | 30,000 gas per ETH push | PadLib |
| `KING_MAX_GAMES` / `KING_MIN_IMPS` | 10 / 5 | PvPPad |
| `LIQUIDITY_MARGIN_PPM` | 1 ppm liquidity haircut so the manager never asks for more than held | PadLiquidity |
| Wall-clock timing | `block.timestamp` for minutes/hours/days; ArbSys block numbers for the RNG commit window | PadGame |
| Genesis name / ticker | "Pepes Value Pepes" / "PVP" | PvPPad |

The launch form fields "DONTBUYTHISTOKEN / DBTT" are not used: the brief's final decision is that this
deployment mints no token and genesis is PVP. If a launch named DONTBUYTHISTOKEN is wanted, anyone can
create it with `launch("DONTBUYTHISTOKEN", "DBTT", url)` after PvP graduates.

## Build and test

```
forge build
FOUNDRY_FUZZ_SEED=0x6db4fb9e8219718221c07e9d6a1b41d1300d50a7ad58787663b260552f351f1f forge test
forge fmt --check
```

solc 0.8.26, via-IR, optimizer 200 runs, `bytecode_hash = "none"`, `cbor_metadata = false`.
forge-std is vendored as plain files under `lib/forge-std`. Tests use a mock ArbSys etched at
`0x64` and a behavioural mock of the v4 PoolManager (`test/mocks/Mocks.sol`); see `docs/AUDIT.md`
for what that does and does not prove. Never deploy, broadcast or call RPCs from this repository;
the launch pipeline deploys from the built bytecode.

Docs: `docs/AUDIT.md` (trust model, findings, limits), `docs/TEST-REPORT.md`, `docs/VERIFY.md`
(source verification on robin.etherscan.io).
