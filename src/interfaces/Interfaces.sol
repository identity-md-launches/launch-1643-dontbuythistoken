// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Arbitrum-stack system precompile at address 0x64 (Robinhood Chain runs Arbitrum's stack).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}

/// @notice ABI-identical mirror of Uniswap v4 PoolKey (Currency and IHooks are addresses on the wire).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice The subset of the Uniswap v4 PoolManager this project uses. BalanceDelta is an int256
/// packing amount0 in the upper 128 bits and amount1 in the lower 128 bits.
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @notice PoolManager storage reads (v4 Extsload); kept apart from IPoolManager so test stubs stay small.
interface IPoolStateReader {
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IPadToken is IERC20Min {
    function initialize(string calldata name_, string calldata symbol_, address game_, address liquidity_) external;
    function unlock() external;
    function unlocked() external view returns (bool);
}

interface IPadGame {
    function initialize(uint256 launchId, address token_, address liquidity_, bool genesis) external;
    function upkeepStep(address caller) external;
    function resolvePending(uint256 max) external;
    function fundPot() external payable;
    function isLiveForKing() external view returns (bool live, uint256 pot);
    function graduated() external view returns (bool);
    function failed() external view returns (bool);
    function ended() external view returns (bool);
}

interface IPvPPad {
    function owner() external view returns (address);
    function king() external view returns (address);
    function liquidity() external view returns (address);
    function opened() external view returns (bool);
    function bindLiquidity() external;
    function startGenesis() external;
    function upkeep() external;
    function upkeepFor(address caller) external;
    function fundCarry() external payable;
    function genesisGraduated() external view returns (bool);
    function genesisId() external view returns (uint256);
    function launchCount() external view returns (uint256);
    function gameOf(uint256 id) external view returns (address);
    function tokenOf(uint256 id) external view returns (address);
}

interface IPadLiquidity {
    function bindKing() external;
    function deployHook(bytes32 salt) external returns (address);
    function graduate(uint256 launchId, address token, uint256 tokenAmount, uint256 vEth, uint256 vTok) external payable;
    function fundBurn() external payable;
    function distribute(uint256 n) external;
    function burnChunk() external;
    function hook() external view returns (address);
    function king() external view returns (address);
}
