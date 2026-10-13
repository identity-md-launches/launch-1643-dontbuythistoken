// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadLib} from "./libs/PadLib.sol";
import {PadHook} from "./PadHook.sol";
import {
    IPoolManager,
    IUnlockCallback,
    IPadToken,
    IPvPPad,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams
} from "./interfaces/Interfaces.sol";

interface IKingView {
    function king() external view returns (address);
}

/// @title PadLiquidity
/// @notice Graduates launches into Uniswap v4 pools (native ETH / token, fee 10000, tickSpacing 200,
/// hooks = PadHook), owns the full-range LP forever, collects its fees for the king, and buys and
/// burns PvP with the burn bucket. All v4 interaction goes through PoolManager.unlock with own funds.
contract PadLiquidity is IUnlockCallback {
    uint24 public constant FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant MIN_TICK = -887_200;
    int24 public constant MAX_TICK = 887_200;
    uint160 internal constant SQRT_MIN_FULL = 4_310_618_291;
    uint160 internal constant SQRT_MAX_FULL = 1_456_195_216_270_955_103_182_949_462_556_801_019_286_893_565_306;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant Q96 = 1 << 96;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BURN_MAX = 0.02 ether;
    uint256 public constant BURN_INTERVAL = 10 minutes;
    uint256 public constant SELL_CHUNK = 2_000_000 ether;
    uint256 internal constant LIQUIDITY_MARGIN_PPM = 1_000_000;

    uint8 internal constant ACT_ADD = 1;
    uint8 internal constant ACT_COLLECT = 2;
    uint8 internal constant ACT_BURN = 3;

    struct Pool {
        uint256 launchId;
        address token;
        uint128 liquidity;
        uint256 ethFees;
        uint256 tokenFees;
        uint256 tokenStash;
    }

    IPoolManager public immutable poolManager;
    address public immutable pad;
    address public king;
    address public hook;
    uint256 public burnBucket;
    uint64 public lastBurnAt;
    uint256 public kingEscrow;
    uint256 public distributeCursor;
    uint256 public totalBurnedEth;
    bool private inUnlock;
    bool private locked;

    Pool[] internal pools;
    mapping(uint256 => uint256) public poolIndexOf; // launchId => index + 1
    mapping(address => uint256) public claimable;

    event KingBound(address indexed king);
    event HookDeployed(address indexed hook, bytes32 salt);
    event Graduated(
        uint256 indexed launchId,
        address indexed token,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 eth,
        uint256 tokens,
        uint256 burnedTokens
    );
    event BurnFunded(address indexed from, uint256 amount);
    event Burned(uint256 ethSpent, uint256 tokensBurned);
    event FeesCollected(uint256 indexed launchId, uint256 eth, uint256 tokens, uint256 tokensSold, uint256 ethFromSale);
    event KingPaid(address indexed king, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);

    modifier guard() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    constructor(address poolManager_, address pad_) {
        require(poolManager_ != address(0) && pad_ != address(0), "zero");
        poolManager = IPoolManager(poolManager_);
        pad = pad_;
        IPvPPad(pad_).bindLiquidity();
    }

    receive() external payable {}

    function bindKing() external {
        require(king == address(0), "bound");
        king = msg.sender;
        emit KingBound(msg.sender);
    }

    // ---- hook ------------------------------------------------------------------------------------
    function deployHook(bytes32 salt) external returns (address h) {
        require(msg.sender == pad, "not pad");
        require(hook == address(0), "deployed");
        h = address(new PadHook{salt: salt}(address(poolManager), address(this)));
        hook = h;
        emit HookDeployed(h, salt);
    }

    /// @notice Init code hash to mine the open salt against (CREATE2 from this contract).
    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(abi.encodePacked(type(PadHook).creationCode, abi.encode(address(poolManager), address(this))));
    }

    function hookAddressFor(bytes32 salt) public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash()))))
            );
    }

    // ---- graduation ------------------------------------------------------------------------------
    function poolKey(address token) public view returns (PoolKey memory) {
        return PoolKey(address(0), token, FEE, TICK_SPACING, hook);
    }

    /// @notice Called by a launch's game inside its graduation: tokens already transferred here, ETH sent.
    function graduate(uint256 launchId, address token, uint256 tokenAmount, uint256 vEth, uint256 vTok)
        external
        payable
        guard
    {
        require(msg.sender == IPvPPad(pad).gameOf(launchId), "not game");
        require(hook != address(0), "pad not open");
        require(poolIndexOf[launchId] == 0, "graduated");
        require(msg.value != 0 && tokenAmount != 0, "empty");
        uint160 sqrtP = uint160(PadLib.sqrt(PadLib.mulDiv(vTok, Q96 * Q96, vEth)));
        if (sqrtP <= SQRT_MIN_FULL) sqrtP = SQRT_MIN_FULL + 1;
        if (sqrtP >= SQRT_MAX_FULL) sqrtP = SQRT_MAX_FULL - 1;
        uint256 l0 = PadLib.mulDiv(msg.value, PadLib.mulDiv(sqrtP, SQRT_MAX_FULL, Q96), SQRT_MAX_FULL - sqrtP);
        uint256 l1 = PadLib.mulDiv(tokenAmount, Q96, sqrtP - SQRT_MIN_FULL);
        uint256 l = l0 < l1 ? l0 : l1;
        l = l - l / LIQUIDITY_MARGIN_PPM;
        require(l != 0 && l <= type(uint128).max, "liquidity");

        PoolKey memory key = poolKey(token);
        poolManager.initialize(key, sqrtP);
        bytes memory res = poolManager.unlock(abi.encode(ACT_ADD, key, l, msg.value, tokenAmount));
        (uint256 usedEth, uint256 usedTok) = abi.decode(res, (uint256, uint256));

        pools.push(Pool(launchId, token, uint128(l), 0, 0, 0));
        poolIndexOf[launchId] = pools.length;
        IPadToken(token).unlock();
        uint256 excess = IPadToken(token).balanceOf(address(this));
        if (excess != 0) require(IPadToken(token).transfer(DEAD, excess), "burn");
        if (msg.value > usedEth) burnBucket += msg.value - usedEth;
        emit Graduated(launchId, token, sqrtP, uint128(l), usedEth, usedTok, excess);
    }

    // ---- fees to the king -----------------------------------------------------------------------
    /// @notice Collects fees from the next `n` pools round-robin, sells the token side (chunk-capped),
    /// and sends all ETH to the current king (held in escrow while there is none).
    function distribute(uint256 n) external guard {
        uint256 count = pools.length;
        if (count == 0 || n == 0) return;
        if (n > count) n = count;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 idx = distributeCursor % count;
            distributeCursor = idx + 1;
            total += _collect(idx);
        }
        address k = king == address(0) ? address(0) : IKingView(king).king();
        uint256 amount = total + kingEscrow;
        if (amount == 0) return;
        if (k == address(0)) {
            kingEscrow = amount;
            return;
        }
        kingEscrow = 0;
        bool ok = PadLib.push(k, amount);
        if (!ok) claimable[k] += amount;
        emit KingPaid(k, amount, ok);
    }

    function _collect(uint256 idx) internal returns (uint256 ethOut) {
        Pool storage p = pools[idx];
        bytes memory res = poolManager.unlock(abi.encode(ACT_COLLECT, poolKey(p.token), idx));
        (uint256 e, uint256 t, uint256 sold, uint256 ethFromSale) =
            abi.decode(res, (uint256, uint256, uint256, uint256));
        p.ethFees += e;
        p.tokenFees += t;
        p.tokenStash = IPadToken(p.token).balanceOf(address(this));
        ethOut = e + ethFromSale;
        emit FeesCollected(p.launchId, e, t, sold, ethFromSale);
    }

    // ---- burn ------------------------------------------------------------------------------------
    function fundBurn() external payable {
        burnBucket += msg.value;
        emit BurnFunded(msg.sender, msg.value);
    }

    /// @notice Buys PvP with up to 0.02 ETH of the burn bucket and sends it to dEaD, once per 10 minutes.
    function burnChunk() external guard {
        if (burnBucket == 0 || poolIndexOf[1] == 0) return;
        if (block.timestamp < lastBurnAt + BURN_INTERVAL) return;
        uint256 amount = burnBucket > BURN_MAX ? BURN_MAX : burnBucket;
        burnBucket -= amount;
        lastBurnAt = uint64(block.timestamp);
        totalBurnedEth += amount;
        bytes memory res = poolManager.unlock(abi.encode(ACT_BURN, poolKey(pools[poolIndexOf[1] - 1].token), amount));
        uint256 tokens = abi.decode(res, (uint256));
        emit Burned(amount, tokens);
    }

    function claim() external guard {
        uint256 amount = claimable[msg.sender];
        require(amount != 0, "nothing");
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim failed");
        emit Claimed(msg.sender, amount);
    }

    // ---- v4 callback -----------------------------------------------------------------------------
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        uint8 action = abi.decode(data, (uint8));
        if (action == ACT_ADD) {
            (, PoolKey memory key, uint256 l, uint256 maxEth, uint256 maxTok) =
                abi.decode(data, (uint8, PoolKey, uint256, uint256, uint256));
            (int256 delta,) =
                poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(l), 0), "");
            (int128 a0, int128 a1) = _split(delta);
            require(a0 <= 0 && a1 <= 0, "delta sign");
            uint256 owe0 = uint256(uint128(-a0));
            uint256 owe1 = uint256(uint128(-a1));
            require(owe0 <= maxEth && owe1 <= maxTok, "owes too much");
            _settleEth(owe0);
            _settleToken(key.currency1, owe1);
            return abi.encode(owe0, owe1);
        }
        if (action == ACT_COLLECT) {
            (, PoolKey memory key, uint256 idx) = abi.decode(data, (uint8, PoolKey, uint256));
            (, int256 fees) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 0, 0), "");
            (int128 f0, int128 f1) = _split(fees);
            uint256 e = f0 > 0 ? uint256(uint128(f0)) : 0;
            uint256 t = f1 > 0 ? uint256(uint128(f1)) : 0;
            if (e != 0) poolManager.take(address(0), address(this), e);
            if (t != 0) poolManager.take(key.currency1, address(this), t);
            uint256 avail = t + pools[idx].tokenStash;
            uint256 sell = avail > SELL_CHUNK ? SELL_CHUNK : avail;
            uint256 ethFromSale;
            if (sell != 0) {
                int256 d = poolManager.swap(key, SwapParams(false, -int256(sell), MAX_SQRT_PRICE_LIMIT), "");
                (int128 s0, int128 s1) = _split(d);
                require(s1 <= 0, "swap sign");
                uint256 tokIn = uint256(uint128(-s1));
                _settleToken(key.currency1, tokIn);
                if (s0 > 0) {
                    ethFromSale = uint256(uint128(s0));
                    poolManager.take(address(0), address(this), ethFromSale);
                }
                sell = tokIn;
            }
            return abi.encode(e, t, sell, ethFromSale);
        }
        if (action == ACT_BURN) {
            (, PoolKey memory key, uint256 amount) = abi.decode(data, (uint8, PoolKey, uint256));
            int256 d = poolManager.swap(key, SwapParams(true, -int256(amount), MIN_SQRT_PRICE_LIMIT), "");
            (int128 s0, int128 s1) = _split(d);
            require(s0 <= 0, "swap sign");
            _settleEth(uint256(uint128(-s0)));
            uint256 out = s1 > 0 ? uint256(uint128(s1)) : 0;
            if (out != 0) poolManager.take(key.currency1, DEAD, out);
            return abi.encode(out);
        }
        revert("bad action");
    }

    function _settleEth(uint256 amount) internal {
        if (amount == 0) return;
        poolManager.settle{value: amount}();
    }

    function _settleToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(token);
        require(IPadToken(token).transfer(address(poolManager), amount), "token");
        poolManager.settle();
    }

    function _split(int256 delta) internal pure returns (int128 a0, int128 a1) {
        assembly ("memory-safe") {
            a0 := sar(128, delta)
            a1 := signextend(15, delta)
        }
    }

    // ---- views -----------------------------------------------------------------------------------
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function getPool(uint256 idx) external view returns (Pool memory) {
        return pools[idx];
    }

    function currentKing() external view returns (address) {
        return king == address(0) ? address(0) : IKingView(king).king();
    }
}
