# Verifying sources on robin.etherscan.io

The launch deploys the five manifest contracts from the bytecode built here. After the deployment
handoff provides addresses, verify each with the exact compiler settings from `foundry.toml`:

- Compiler: solc 0.8.26, EVM version cancun, optimizer on (200 runs), via-IR on,
  `bytecode_hash = "none"`, `cbor_metadata = false`.
- Standard JSON input is the easiest route: `forge verify-contract --show-standard-json-input`
  prints it without sending anything.

```
forge verify-contract <address> src/PadToken.sol:PadToken --chain-id 4663 \
  --verifier etherscan --verifier-url https://robin.etherscan.io/api --watch
forge verify-contract <address> src/PadGame.sol:PadGame --chain-id 4663 ...
forge verify-contract <address> src/PvPPad.sol:PvPPad --chain-id 4663 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
     0x5b95a971b4583a5f011e9da082acdd679b870d06 <PadToken> <PadGame>) ...
forge verify-contract <address> src/PadLiquidity.sol:PadLiquidity --chain-id 4663 \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
     0x8366a39cc670b4001a1121b8f6a443a643e40951 <PvPPad>) ...
forge verify-contract <address> src/KingOfThePad.sol:KingOfThePad --chain-id 4663 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
     <PvPPad> <PadLiquidity> 0x5b95a971b4583a5f011e9da082acdd679b870d06) ...
```

`PadHook` is deployed later by `openPad(salt)`; verify it at `PvPPad.hook()` with constructor args
`(poolManager, padLiquidity)`. Clones (tokens and games) are EIP-1167 proxies: the explorer shows
them as proxies of `PadToken` / `PadGame` once the templates are verified.

Verification is the deployer's step; this repository never broadcasts or calls RPCs.
