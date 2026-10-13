// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "./interfaces/Interfaces.sol";

/// @title PadHook
/// @notice Uniswap v4 hook with only the beforeInitialize permission: a pool using it can only be
/// initialized by PadLiquidity. Deployed by PadLiquidity (CREATE2) when the pad opens, never by the
/// launch manifest, because its address must carry exactly the beforeInitialize flag (bit 13).
contract PadHook {
    address public immutable poolManager;
    address public immutable liquidity;

    constructor(address poolManager_, address liquidity_) {
        poolManager = poolManager_;
        liquidity = liquidity_;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        require(msg.sender == poolManager, "not pool manager");
        require(sender == liquidity, "only PadLiquidity");
        return this.beforeInitialize.selector;
    }
}
