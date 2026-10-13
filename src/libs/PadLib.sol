// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Internal-only helpers (inlined by the compiler, so no link placeholders in bytecode).
library PadLib {
    uint256 internal constant PUSH_GAS = 30_000;

    /// @dev Deploys an EIP-1167 minimal proxy pointing at `implementation`.
    function clone(address implementation) internal returns (address instance) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
        require(instance != address(0), "clone failed");
    }

    /// @dev Gas-capped ETH push; returns false instead of reverting so the caller can make it claimable.
    function push(address to, uint256 amount) internal returns (bool ok) {
        if (amount == 0) return true;
        assembly ("memory-safe") {
            ok := call(PUSH_GAS, to, amount, 0, 0, 0, 0)
        }
    }

    /// @dev floor(a * b / d) with full 512-bit intermediate precision.
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            require(d > prod1, "mulDiv overflow");
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly ("memory-safe") {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            result = prod0 * inv;
        }
    }

    /// @dev floor(sqrt(x)).
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 r = 1;
        uint256 v = x;
        if (v >= 1 << 128) {
            v >>= 128;
            r <<= 64;
        }
        if (v >= 1 << 64) {
            v >>= 64;
            r <<= 32;
        }
        if (v >= 1 << 32) {
            v >>= 32;
            r <<= 16;
        }
        if (v >= 1 << 16) {
            v >>= 16;
            r <<= 8;
        }
        if (v >= 1 << 8) {
            v >>= 8;
            r <<= 4;
        }
        if (v >= 1 << 4) {
            v >>= 4;
            r <<= 2;
        }
        if (v >= 1 << 2) r <<= 1;
        unchecked {
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            uint256 r1 = x / r;
            z = r < r1 ? r : r1;
        }
    }

    function abs(int256 v) internal pure returns (uint256) {
        return v < 0 ? uint256(-v) : uint256(v);
    }
}
