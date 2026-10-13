// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadLib} from "../../src/libs/PadLib.sol";
import {
    IPoolManager,
    IUnlockCallback,
    IERC20Min,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams
} from "../../src/interfaces/Interfaces.sol";

/// @notice Test stand-in for the ArbSys precompile at 0x64. Block number is set by tests; hashes are
/// deterministic from the block number and only served inside the 256-block window, as on Arbitrum.
contract MockArbSys {
    uint256 public number = 1000;

    function set(uint256 n) external {
        number = n;
    }

    function advance(uint256 n) external {
        number += n;
    }

    function arbBlockNumber() external view returns (uint256) {
        return number;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < number && n + 256 >= number, "invalid block number");
        return keccak256(abi.encode("arb", n));
    }
}

interface IHookInit {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
}

/// @notice Minimal, local-only model of the Uniswap v4 PoolManager: unlock/callback accounting, a
/// hook call on initialize, full-range liquidity amounts, a constant-product swap with the pool fee,
/// and fee accrual read back through a zero-delta modifyLiquidity. It is a behavioural stand-in for
/// tests, not the real pool math.
contract MockPoolManager is IPoolManager {
    uint256 internal constant Q96 = 1 << 96;
    uint160 internal constant SQRT_MIN_FULL = 4_310_618_291;
    uint160 internal constant SQRT_MAX_FULL = 1_456_195_216_270_955_103_182_949_462_556_801_019_286_893_565_306;

    struct PoolState {
        bool initialized;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 reserve0;
        uint256 reserve1;
        uint256 fees0;
        uint256 fees1;
    }

    mapping(bytes32 => PoolState) public pools;
    mapping(address => int256) public delta;
    address public locker;
    address public syncedToken;
    uint256 public syncedBalance;
    uint256 public initializeCount;
    uint256 public swapCount;

    function poolId(PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "already unlocked");
        locker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(delta[address(0)] == 0, "eth delta");
        if (syncedToken != address(0)) require(delta[syncedToken] == 0, "token delta");
        locker = address(0);
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        PoolState storage p = pools[poolId(key)];
        require(!p.initialized, "initialized");
        require(key.currency0 < key.currency1, "order");
        require(key.fee == 10_000 && key.tickSpacing == 200, "key");
        if (key.hooks != address(0)) {
            require(uint160(key.hooks) & (1 << 13) != 0, "hook flags");
            bytes4 sel = IHookInit(key.hooks).beforeInitialize(msg.sender, key, sqrtPriceX96);
            require(sel == IHookInit.beforeInitialize.selector, "hook");
        }
        p.initialized = true;
        p.sqrtPriceX96 = sqrtPriceX96;
        initializeCount++;
        return 0;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata)
        external
        returns (int256 callerDelta, int256 feesAccrued)
    {
        require(msg.sender == locker, "locked");
        require(params.tickLower == -887_200 && params.tickUpper == 887_200, "range");
        PoolState storage p = pools[poolId(key)];
        require(p.initialized, "no pool");
        feesAccrued = _pack(int256(p.fees0), int256(p.fees1));
        if (p.fees0 != 0) delta[key.currency0] += int256(p.fees0);
        if (p.fees1 != 0) delta[key.currency1] += int256(p.fees1);
        p.fees0 = 0;
        p.fees1 = 0;
        if (params.liquidityDelta > 0) {
            uint256 l = uint256(params.liquidityDelta);
            uint256 a0 =
                PadLib.mulDiv(l, PadLib.mulDiv(SQRT_MAX_FULL - p.sqrtPriceX96, Q96, SQRT_MAX_FULL), p.sqrtPriceX96) + 1;
            uint256 a1 = PadLib.mulDiv(l, p.sqrtPriceX96 - SQRT_MIN_FULL, Q96) + 1;
            p.liquidity += uint128(l);
            p.reserve0 += a0;
            p.reserve1 += a1;
            delta[key.currency0] -= int256(a0);
            delta[key.currency1] -= int256(a1);
            callerDelta = _pack(-int256(a0), -int256(a1)) + feesAccrued;
        } else {
            require(params.liquidityDelta == 0, "no removal in mock");
            callerDelta = feesAccrued;
        }
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256) {
        require(msg.sender == locker, "locked");
        PoolState storage p = pools[poolId(key)];
        require(p.initialized && p.reserve0 != 0 && p.reserve1 != 0, "no liquidity");
        require(params.amountSpecified < 0, "exact input only");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 fee = amountIn * key.fee / 1_000_000;
        uint256 net = amountIn - fee;
        swapCount++;
        if (params.zeroForOne) {
            uint256 out = p.reserve1 * net / (p.reserve0 + net);
            p.reserve0 += net;
            p.reserve1 -= out;
            p.fees0 += fee;
            delta[key.currency0] -= int256(amountIn);
            delta[key.currency1] += int256(out);
            return _pack(-int256(amountIn), int256(out));
        } else {
            uint256 out = p.reserve0 * net / (p.reserve1 + net);
            p.reserve1 += net;
            p.reserve0 -= out;
            p.fees1 += fee;
            delta[key.currency1] -= int256(amountIn);
            delta[key.currency0] += int256(out);
            return _pack(int256(out), -int256(amountIn));
        }
    }

    function sync(address currency) external {
        syncedToken = currency;
        syncedBalance = IERC20Min(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        require(msg.sender == locker, "locked");
        if (msg.value != 0) {
            delta[address(0)] += int256(msg.value);
            return msg.value;
        }
        uint256 paid = IERC20Min(syncedToken).balanceOf(address(this)) - syncedBalance;
        delta[syncedToken] += int256(paid);
        syncedBalance = 0;
        return paid;
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == locker, "locked");
        delta[currency] -= int256(amount);
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth take");
        } else {
            require(IERC20Min(currency).transfer(to, amount), "token take");
        }
    }

    /// @dev Test helper: simulate trading fees accrued to the position.
    function creditFees(PoolKey memory key, uint256 f0, uint256 f1) external payable {
        PoolState storage p = pools[poolId(key)];
        p.fees0 += f0;
        p.fees1 += f1;
        p.reserve1 += f1;
    }

    function getPool(PoolKey memory key) external view returns (PoolState memory) {
        return pools[poolId(key)];
    }

    function _pack(int256 a0, int256 a1) internal pure returns (int256 d) {
        assembly ("memory-safe") {
            d := or(shl(128, a0), and(a1, 0xffffffffffffffffffffffffffffffff))
        }
    }

    receive() external payable {}
}

/// @notice Receiver that rejects ETH, to exercise the claimable fallback.
contract Rejector {
    receive() external payable {
        revert("no");
    }
}
