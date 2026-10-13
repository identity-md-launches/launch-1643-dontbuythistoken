// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadLib} from "./libs/PadLib.sol";
import {IArbSys, IPadToken, IPvPPad, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PadGame
/// @notice Template (EIP-1167 cloned per launch) holding one launch's bonding curve and its Spireth game.
/// Wall-clock rules (signup, cooldown, death, 60 min cap) use block.timestamp; randomness and the
/// commit window use ArbSys (0x64) arbBlockNumber / arbBlockHash, never block.number or blockhash.
contract PadGame {
    using PadLib for *;

    // ---- constants -------------------------------------------------------------------------
    IArbSys internal constant ARB = IArbSys(address(0x64));
    uint256 public constant ROLL_PRICE = 0.002 ether;
    uint256 public constant COOLDOWN = 60;
    uint256 public constant SIGNUP = 10 minutes;
    uint256 public constant DEATH = 10 minutes;
    uint256 public constant MAX_PLAY = 60 minutes;
    uint256 public constant MAX_IMPS = 200;
    int256 public constant HEIGHT_CAP = 50;
    uint256 public constant RESOLVE_BATCH = 8;
    uint256 public constant HASH_WINDOW = 256;
    uint256 public constant VETH = 1 ether;
    uint256 public constant VTOK = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant K = VETH * VTOK;
    uint256 public constant FINALIZER_BPS = 50;
    uint256 public constant FINALIZER_MAX = 0.005 ether;
    /// @notice Funded ETH (carry pot, king share) is paid out only when at least this many Imps live at the end.
    uint256 public constant FUNDED_MIN_LIVING = 5;
    /// @notice Funded ETH paid out is capped at this multiple of the roll-earned pot; the rest returns to the carry.
    uint256 public constant FUNDED_RELEASE_MULTIPLE = 3;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---- types ----------------------------------------------------------------------------
    struct Imp {
        address owner;
        int16 height;
        uint40 lastRoll;
        uint40 heightReachedAt; // commit L2 block of the roll that reached the current height
        uint32 nonce;
        uint32 pendingRoll; // roll index + 1, 0 when none pending
        uint32 heightRoll; // roll index + 1 that reached the current height (tie-break inside one block)
    }

    struct Roll {
        uint32 imp;
        uint32 nonce;
        uint64 commitBlock;
        bool resolved;
        bool expired;
        int8 delta;
    }

    // ---- state ----------------------------------------------------------------------------
    address public pad;
    address public token;
    address public liquidity;
    uint256 public launchId;
    bool public genesis;
    bool private initialized;
    bool private locked;

    uint256 public ethRaised;
    uint256 public tokensSold;
    uint256 public pot; // total: roll-earned + funded

    uint64 public firstMintAt;
    uint64 public bellAt;
    uint64 public maxActivity;
    address public bellRinger;
    bool public finalized;
    bool public graduated;
    bool public failed;
    uint32 public livingAtEnd;
    uint32 public paidAtEnd;

    Imp[] internal imps;
    mapping(address => uint256) public impOf; // index + 1
    Roll[] internal rolls;
    uint256 public nextPending;
    uint256 public pendingCount;
    mapping(address => uint256) public claimable;
    uint256 public fundedPot; // part of `pot` that came from the pad (carry pot, king share)

    // ---- events ---------------------------------------------------------------------------
    event Initialized(uint256 indexed launchId, address indexed token, bool genesis);
    event Minted(address indexed owner, uint256 indexed imp, bool signupStarted);
    event Rolled(address indexed owner, uint256 indexed imp, uint256 indexed roll, uint256 commitBlock, uint256 tokens);
    event Resolved(uint256 indexed roll, uint256 indexed imp, int256 delta, int256 height, bool expired);
    event Bell(uint256 indexed imp, address indexed ringer, int256 height);
    event CurveBuy(uint256 ethIn, uint256 ethToCurve, uint256 tokensOut, uint256 ethToPot);
    event PotFunded(address indexed from, uint256 amount);
    event Finalized(address indexed finalizer, uint256 pot, uint256 living, uint256 paid, bool bell);
    event FundedReturned(uint256 amount);
    event Paid(address indexed to, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);
    event Graduated(uint256 eth, uint256 tokens);
    event Failed(uint256 tokensBurned);

    modifier guard() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        initialized = true;
    }

    // ---- lifecycle ------------------------------------------------------------------------
    function initialize(uint256 launchId_, address token_, address liquidity_, bool genesis_) external {
        require(!initialized, "initialized");
        initialized = true;
        pad = msg.sender;
        token = token_;
        liquidity = liquidity_;
        launchId = launchId_;
        genesis = genesis_;
        emit Initialized(launchId_, token_, genesis_);
    }

    /// @notice Free Imp mint: the first mint opens a 10 minute signup, one Imp per wallet, 200 max.
    function mint() external guard {
        require(IPvPPad(pad).opened(), "pad not open");
        require(impOf[msg.sender] == 0, "one imp per wallet");
        require(imps.length < MAX_IMPS, "full");
        bool first = firstMintAt == 0;
        if (first) {
            firstMintAt = uint64(block.timestamp);
            maxActivity = uint64(block.timestamp + SIGNUP);
        } else {
            require(block.timestamp < firstMintAt + SIGNUP, "signup over");
        }
        imps.push(Imp(msg.sender, 0, 0, 0, 0, 0, 0));
        impOf[msg.sender] = imps.length;
        emit Minted(msg.sender, imps.length - 1, first);
        _resolve(RESOLVE_BATCH);
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Roll the dice: 0.002 ETH, 60 s cooldown, 90% curve buy, 8% pot, 2% burn (genesis: pot).
    function roll() external payable guard {
        require(IPvPPad(pad).opened(), "pad not open");
        require(msg.value == ROLL_PRICE, "roll price");
        uint256 idx = impOf[msg.sender];
        require(idx != 0, "no imp");
        require(firstMintAt != 0 && block.timestamp >= playStart(), "not playing");
        require(!ended(), "game over");
        Imp storage imp = imps[idx - 1];
        require(_lastActivity(imp) + DEATH > block.timestamp, "imp dead");
        require(imp.lastRoll == 0 || imp.lastRoll + COOLDOWN <= block.timestamp, "cooldown");
        if (imp.pendingRoll != 0) _resolveRoll(imp.pendingRoll - 1);
        require(!ended(), "game over"); // the previous roll may have rung the bell just now

        uint256 curveEth = msg.value * 90 / 100;
        uint256 burnEth = msg.value * 2 / 100;
        uint256 potEth = msg.value - curveEth - burnEth;
        (uint256 tokensOut, uint256 ethUsed) = _buy(curveEth);
        potEth += curveEth - ethUsed;
        if (genesis) potEth += burnEth;
        pot += potEth;
        emit CurveBuy(msg.value, ethUsed, tokensOut, potEth);

        uint256 rollId = rolls.length;
        rolls.push(Roll(uint32(idx - 1), imp.nonce, uint64(ARB.arbBlockNumber()), false, false, 0));
        imp.nonce += 1;
        imp.pendingRoll = uint32(rollId + 1);
        imp.lastRoll = uint40(block.timestamp);
        if (block.timestamp > maxActivity) maxActivity = uint64(block.timestamp);
        pendingCount += 1;
        emit Rolled(msg.sender, idx - 1, rollId, rolls[rollId].commitBlock, tokensOut);

        if (tokensOut != 0) require(IPadToken(token).transfer(msg.sender, tokensOut), "token");
        if (!genesis && burnEth != 0) IPadLiquidity(liquidity).fundBurn{value: burnEth}();
        _resolve(RESOLVE_BATCH);
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Permissionless upkeep for this game plus the pad's bounded upkeep.
    function poke() external guard {
        _resolve(RESOLVE_BATCH);
        if (firstMintAt != 0) {
            if (!finalized) _finalize(msg.sender);
            else if (!graduated) _graduate();
        }
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Ranks living Imps and pays the pot. Permissionless once the game has ended.
    function finalize() external guard {
        _resolve(RESOLVE_BATCH);
        require(_finalize(msg.sender), "not finalizable");
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Moves curve ETH and remaining tokens into the v4 pool (or burns all when no ETH was raised).
    function graduate() external guard {
        require(_graduate(), "not graduable");
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Pad-driven bounded upkeep: resolve, end, finalize, graduate, one step per call.
    function upkeepStep(address caller) external {
        require(msg.sender == pad, "not pad");
        if (locked || firstMintAt == 0) return;
        locked = true;
        _resolve(RESOLVE_BATCH);
        if (!finalized) {
            _finalize(caller);
        } else if (!graduated) {
            _graduate();
        }
        locked = false;
    }

    function resolvePending(uint256 max) external {
        _resolve(max);
    }

    /// @notice Pad-only top-up (carry pot at creation, king's games share). Tracked apart from roll
    /// income: it is paid out only to a game with >= 5 living Imps, capped at 3x the roll-earned pot,
    /// and otherwise returns to the carry pot at the end.
    function fundPot() external payable {
        require(msg.sender == pad, "not pad");
        require(!finalized, "finalized");
        pot += msg.value;
        fundedPot += msg.value;
        emit PotFunded(msg.sender, msg.value);
    }

    function claim() external guard {
        uint256 amount = claimable[msg.sender];
        require(amount != 0, "nothing");
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim failed");
        emit Claimed(msg.sender, amount);
    }

    // ---- views ------------------------------------------------------------------------------
    function playStart() public view returns (uint256) {
        return firstMintAt == 0 ? 0 : firstMintAt + SIGNUP;
    }

    function hardEnd() public view returns (uint256) {
        return firstMintAt == 0 ? 0 : firstMintAt + MAX_PLAY;
    }

    /// @notice The moment the game ends (or would end if nothing else happens): the bell, 60 minutes
    /// after the first mint, or 10 minutes after the last activity (every Imp dead).
    function endTime() public view returns (uint256 e) {
        if (firstMintAt == 0) return 0;
        e = hardEnd();
        uint256 allDead = uint256(maxActivity) + DEATH;
        if (allDead < e) e = allDead;
        if (bellAt != 0 && bellAt < e) e = bellAt;
    }

    function ended() public view returns (bool) {
        return firstMintAt != 0 && block.timestamp >= endTime();
    }

    function bellRang() public view returns (bool) {
        return bellAt != 0 && bellAt == endTime();
    }

    /// @notice 0 waiting, 1 signup, 2 play, 3 ended, 4 finalized, 5 graduated, 6 failed.
    function status() external view returns (uint8) {
        if (failed) return 6;
        if (graduated) return 5;
        if (finalized) return 4;
        if (firstMintAt == 0) return 0;
        if (block.timestamp < playStart()) return 1;
        if (!ended()) return 2;
        return 3;
    }

    /// @notice Live for the king's split: signup started, not ended, >= 5 Imps. The weight is the
    /// roll-earned pot, so funded ETH cannot steer the split.
    function isLiveForKing() external view returns (bool live, uint256 potSize) {
        live = firstMintAt != 0 && !ended() && imps.length >= 5;
        potSize = pot - fundedPot;
    }

    /// @notice ETH the pot earned from rolls (8% of each, plus the genesis burn share and sold-out overflow).
    function rollPot() external view returns (uint256) {
        return pot - fundedPot;
    }

    function impCount() external view returns (uint256) {
        return imps.length;
    }

    function getImp(uint256 i) external view returns (Imp memory) {
        return imps[i];
    }

    function isAlive(uint256 i) public view returns (bool) {
        if (firstMintAt == 0 || i >= imps.length) return false;
        uint256 at = ended() ? endTime() : block.timestamp;
        return _lastActivity(imps[i]) + DEATH > at;
    }

    function rollCount() external view returns (uint256) {
        return rolls.length;
    }

    function getRoll(uint256 i) external view returns (Roll memory) {
        return rolls[i];
    }

    function curveState() external view returns (uint256 vEth, uint256 vTok, uint256 remaining) {
        vEth = VETH + ethRaised;
        vTok = VTOK - tokensSold;
        remaining = CURVE_SUPPLY - tokensSold;
    }

    function quote(uint256 ethIn) public view returns (uint256 tokensOut, uint256 ethUsed) {
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        if (remaining == 0 || ethIn == 0) return (0, 0);
        uint256 vEth = VETH + ethRaised;
        uint256 vTok = VTOK - tokensSold;
        uint256 newTok = (K + vEth + ethIn - 1) / (vEth + ethIn);
        tokensOut = vTok > newTok ? vTok - newTok : 0;
        ethUsed = ethIn;
        if (tokensOut >= remaining) {
            tokensOut = remaining;
            ethUsed = K / (VTOK - CURVE_SUPPLY) - vEth;
            if (ethUsed > ethIn) ethUsed = ethIn;
        }
    }

    // ---- internals --------------------------------------------------------------------------
    function _lastActivity(Imp storage imp) internal view returns (uint256) {
        return imp.lastRoll == 0 ? playStart() : imp.lastRoll;
    }

    function _buy(uint256 ethIn) internal returns (uint256 tokensOut, uint256 ethUsed) {
        (tokensOut, ethUsed) = quote(ethIn);
        ethRaised += ethUsed;
        tokensSold += tokensOut;
    }

    function _resolve(uint256 max) internal {
        uint256 n = rolls.length;
        uint256 done;
        while (done < max && nextPending < n) {
            if (rolls[nextPending].resolved) {
                nextPending += 1;
                continue;
            }
            if (!_resolveRoll(nextPending)) break;
            nextPending += 1;
            done += 1;
        }
    }

    function _resolveRoll(uint256 id) internal returns (bool) {
        Roll storage r = rolls[id];
        if (r.resolved) return true;
        uint256 cur = ARB.arbBlockNumber();
        uint256 commit = r.commitBlock;
        Imp storage imp = imps[r.imp];
        int256 h = imp.height;
        int256 d;
        bool expired;
        if (commit + 1 + HASH_WINDOW < cur) {
            expired = true;
            if (h > 0) d = h >= 4 ? int256(-4) : -h;
            else if (h < 0) d = h <= -4 ? int256(4) : -h;
        } else if (cur > commit + 3) {
            bytes32 h1 = ARB.arbBlockHash(commit + 1);
            bytes32 h2 = ARB.arbBlockHash(commit + 2);
            bytes32 h3 = ARB.arbBlockHash(commit + 3);
            uint256 rand = uint256(keccak256(abi.encode(address(this), uint256(r.imp), uint256(r.nonce), h1, h2, h3)));
            uint256 face = rand % 8;
            d = face < 4 ? -int256(face + 1) : int256(face - 3);
        } else {
            return false;
        }
        r.resolved = true;
        r.expired = expired;
        r.delta = int8(d);
        pendingCount -= 1;
        if (imp.pendingRoll == id + 1) imp.pendingRoll = 0;
        int256 nh = h + d;
        if (nh > HEIGHT_CAP) nh = HEIGHT_CAP;
        if (nh < -HEIGHT_CAP) nh = -HEIGHT_CAP;
        if (nh != h) {
            imp.height = int16(nh);
            imp.heightReachedAt = uint40(commit);
            imp.heightRoll = uint32(id + 1);
        }
        emit Resolved(id, r.imp, d, nh, expired);
        bool alive = _lastActivity(imp) + DEATH > block.timestamp;
        if (alive && !expired && (nh == HEIGHT_CAP || nh == -HEIGHT_CAP) && bellAt == 0 && !ended()) {
            bellAt = uint64(block.timestamp);
            bellRinger = imp.owner;
            emit Bell(r.imp, imp.owner, nh);
        }
        return true;
    }

    function _finalize(address finalizer) internal returns (bool) {
        if (finalized || !ended() || pendingCount != 0) return false;
        finalized = true;
        uint256 end = endTime();
        uint256 n = imps.length;
        // one packed key per living Imp, sorted in memory (heap sort: O(n log n) whatever the order)
        uint256[] memory keys = new uint256[](n);
        uint256 living;
        for (uint256 i; i < n; ++i) {
            Imp storage imp = imps[i];
            if (_lastActivity(imp) + DEATH <= end) continue;
            keys[living++] = _sortKey(imp, i);
        }
        if (living > 1) _heapSort(keys, living);
        uint256 p = pot;
        uint256 funded = fundedPot;
        uint256 earned = p - funded;
        pot = 0;
        fundedPot = 0;
        // finalizer fee: 0.5% of the pot, max 0.005 ETH, paid from roll-earned ETH only
        uint256 fee = p * FINALIZER_BPS / 10_000;
        if (fee > FINALIZER_MAX) fee = FINALIZER_MAX;
        if (fee > earned) fee = earned;
        if (finalizer == address(0)) fee = 0;
        p -= fee;
        // funded ETH is released only to a game with enough living Imps, and at most 3x what rolls earned
        uint256 returned;
        if (living < FUNDED_MIN_LIVING) returned = funded;
        else if (funded > earned * FUNDED_RELEASE_MULTIPLE) returned = funded - earned * FUNDED_RELEASE_MULTIPLE;
        if (returned > p) returned = p;
        p -= returned;
        bool bell = bellAt != 0 && bellAt == end;
        uint256 paid;
        uint256 toCarry = returned;
        if (living == 0) {
            toCarry += p;
        } else {
            uint256 bellShare = bell ? p * 20 / 100 : 0;
            uint256 rankShare = p - bellShare;
            paid = (living + 1) / 2;
            uint256 weightSum = paid * (paid + 1) / 2;
            uint256 sent;
            for (uint256 r; r < paid; ++r) {
                uint256 amount = rankShare * (paid - r) / weightSum;
                sent += amount;
                _pay(imps[_keyIndex(keys[living - 1 - r])].owner, amount);
            }
            if (bellShare != 0) _pay(bellRinger, bellShare);
            toCarry += rankShare - sent;
        }
        livingAtEnd = uint32(living);
        paidAtEnd = uint32(paid);
        if (fee != 0) _pay(finalizer, fee);
        if (returned != 0) emit FundedReturned(returned);
        if (toCarry != 0) IPvPPad(pad).fundCarry{value: toCarry}();
        emit Finalized(finalizer, p, living, paid, bell);
        return true;
    }

    /// @dev Higher key ranks first: |height| desc, then earlier heightReachedAt (commit block), then
    /// earlier roll, then lower Imp index. The index sits in the low 8 bits (MAX_IMPS <= 256).
    function _sortKey(Imp storage imp, uint256 index) internal view returns (uint256) {
        return (PadLib.abs(imp.height) << 80) | (uint256(type(uint40).max - imp.heightReachedAt) << 40)
            | (uint256(type(uint32).max - imp.heightRoll) << 8) | (255 - index);
    }

    function _keyIndex(uint256 key) internal pure returns (uint256) {
        return 255 - (key & 0xFF);
    }

    /// @dev In-place ascending heap sort of a[0..n).
    function _heapSort(uint256[] memory a, uint256 n) internal pure {
        for (uint256 i = n / 2; i > 0; --i) {
            _siftDown(a, i - 1, n);
        }
        for (uint256 last = n - 1; last > 0; --last) {
            (a[0], a[last]) = (a[last], a[0]);
            _siftDown(a, 0, last);
        }
    }

    function _siftDown(uint256[] memory a, uint256 root, uint256 n) internal pure {
        while (true) {
            uint256 child = 2 * root + 1;
            if (child >= n) return;
            if (child + 1 < n && a[child + 1] > a[child]) ++child;
            if (a[root] >= a[child]) return;
            (a[root], a[child]) = (a[child], a[root]);
            root = child;
        }
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = PadLib.push(to, amount);
        if (!ok) claimable[to] += amount;
        emit Paid(to, amount, ok);
    }

    function _graduate() internal returns (bool) {
        if (!finalized || graduated) return false;
        graduated = true;
        uint256 bal = IPadToken(token).balanceOf(address(this));
        if (ethRaised == 0) {
            failed = true;
            if (bal != 0) require(IPadToken(token).transfer(DEAD, bal), "burn");
            emit Failed(bal);
            return true;
        }
        require(IPadToken(token).transfer(liquidity, bal), "token");
        IPadLiquidity(liquidity).graduate{value: ethRaised}(launchId, token, bal, VETH + ethRaised, VTOK - tokensSold);
        emit Graduated(ethRaised, bal);
        return true;
    }
}
