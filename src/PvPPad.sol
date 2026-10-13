// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadLib} from "./libs/PadLib.sol";
import {IPadToken, IPadGame, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PvPPad
/// @notice Registry, clone factory, carry pot and open switch of the PvP Pad.
contract PvPPad {
    uint256 public constant OPEN_DELAY = 30 days;
    uint256 public constant MAX_NAME = 32;
    uint256 public constant MAX_TICKER = 10;
    uint256 public constant MAX_URL = 200;
    uint256 public constant KING_MAX_GAMES = 10;
    uint256 public constant KING_MIN_IMPS = 5;
    uint160 internal constant HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;

    struct Launch {
        address token;
        address game;
        address creator;
        uint64 createdAt;
        string name;
        string ticker;
        string imageURL;
    }

    address public immutable owner;
    address public immutable tokenTemplate;
    address public immutable gameTemplate;
    uint64 public immutable deployedAt;

    address public liquidity;
    address public king;
    bool public opened;
    bytes32 public openSalt;
    address public hook;
    uint256 public carryPot;
    uint256 public upkeepCursor;
    bool private locked;

    Launch[] internal launches;
    mapping(address => bool) public isGame;

    event LiquidityBound(address indexed liquidity);
    event KingBound(address indexed king);
    event Opened(address indexed by, bytes32 salt, address hook);
    event Launched(
        uint256 indexed id, address indexed token, address indexed game, address creator, string name, string ticker
    );
    event CarryFunded(address indexed from, uint256 amount);
    event CarryPaid(uint256 indexed id, uint256 amount);
    event GamesFunded(uint256 amount, uint256 games);

    constructor(address owner_, address tokenTemplate_, address gameTemplate_) {
        require(owner_ != address(0) && tokenTemplate_ != address(0) && gameTemplate_ != address(0), "zero");
        owner = owner_;
        tokenTemplate = tokenTemplate_;
        gameTemplate = gameTemplate_;
        deployedAt = uint64(block.timestamp);
    }

    // ---- one-shot bindings from later constructors --------------------------------------------
    function bindLiquidity() external {
        require(liquidity == address(0), "bound");
        liquidity = msg.sender;
        emit LiquidityBound(msg.sender);
    }

    /// @notice Called once by KingOfThePad's constructor: binds the king contract and creates launch #1.
    function startGenesis() external {
        require(king == address(0), "bound");
        require(liquidity != address(0), "no liquidity");
        king = msg.sender;
        emit KingBound(msg.sender);
        _create("Pepes Value Pepes", "PVP", "", owner, true);
    }

    // ---- open switch ---------------------------------------------------------------------------
    /// @notice Opens the pad once: by the owner, or by anyone 30 days after deployment. Deploys PadHook
    /// through PadLiquidity with `salt`; reverts unless the hook address carries exactly the
    /// beforeInitialize flag.
    function openPad(bytes32 salt) external {
        require(!opened, "opened");
        require(msg.sender == owner || block.timestamp >= deployedAt + OPEN_DELAY, "not yet");
        require(liquidity != address(0) && king != address(0), "not bound");
        opened = true;
        openSalt = salt;
        address h = IPadLiquidity(liquidity).deployHook(salt);
        require(uint160(h) & HOOK_MASK == BEFORE_INITIALIZE_FLAG, "hook flags");
        hook = h;
        emit Opened(msg.sender, salt, h);
    }

    // ---- launches --------------------------------------------------------------------------------
    function launch(string calldata name, string calldata ticker, string calldata imageURL)
        external
        returns (uint256 id)
    {
        require(opened, "pad not open");
        require(genesisGraduated(), "genesis not graduated");
        require(bytes(name).length != 0 && bytes(name).length <= MAX_NAME, "name");
        require(bytes(ticker).length != 0 && bytes(ticker).length <= MAX_TICKER, "ticker");
        require(bytes(imageURL).length <= MAX_URL, "url");
        id = _create(name, ticker, imageURL, msg.sender, false);
        upkeep();
    }

    function _create(string memory name, string memory ticker, string memory url, address creator, bool genesis)
        internal
        returns (uint256 id)
    {
        address token = PadLib.clone(tokenTemplate);
        address game = PadLib.clone(gameTemplate);
        id = launches.length + 1;
        launches.push(Launch(token, game, creator, uint64(block.timestamp), name, ticker, url));
        isGame[game] = true;
        IPadToken(token).initialize(name, ticker, game, liquidity);
        IPadGame(game).initialize(id, token, liquidity, genesis);
        emit Launched(id, token, game, creator, name, ticker);
        uint256 carry = carryPot;
        if (carry != 0) {
            carryPot = 0;
            IPadGame(game).fundPot{value: carry}();
            emit CarryPaid(id, carry);
        }
    }

    // ---- pots ------------------------------------------------------------------------------------
    function fundCarry() external payable {
        carryPot += msg.value;
        emit CarryFunded(msg.sender, msg.value);
    }

    /// @notice King's 50% share: pots of live games with >= 5 Imps among the last 10 launches, weighted
    /// by pot size (equal split when every pot is empty); none live: carry pot.
    function fundGames() external payable {
        require(msg.sender == king, "not king");
        uint256 n = launches.length;
        uint256 from = n > KING_MAX_GAMES ? n - KING_MAX_GAMES : 0;
        address[] memory games = new address[](n - from);
        uint256[] memory pots = new uint256[](n - from);
        uint256 count;
        uint256 total;
        for (uint256 i = from; i < n; ++i) {
            (bool live, uint256 p) = IPadGame(launches[i].game).isLiveForKing();
            if (!live) continue;
            games[count] = launches[i].game;
            pots[count] = p;
            total += p;
            ++count;
        }
        if (count == 0) {
            carryPot += msg.value;
            emit CarryFunded(msg.sender, msg.value);
            return;
        }
        uint256 sent;
        for (uint256 i; i < count; ++i) {
            uint256 share = total == 0 ? msg.value / count : msg.value * pots[i] / total;
            if (i == count - 1) share = msg.value - sent;
            sent += share;
            if (share != 0) IPadGame(games[i]).fundPot{value: share}();
        }
        emit GamesFunded(msg.value, count);
    }

    // ---- upkeep ----------------------------------------------------------------------------------
    /// @notice Bounded upkeep: the latest game, one older game (round-robin), two pools, one burn chunk.
    function upkeep() public {
        _upkeep(msg.sender);
    }

    /// @notice Games call this so the finalizer fee of upkeep work goes to their caller, not the game.
    function upkeepFor(address caller) external {
        require(isGame[msg.sender], "not game");
        _upkeep(caller);
    }

    function _upkeep(address caller) internal {
        if (locked) return;
        locked = true;
        uint256 n = launches.length;
        if (n != 0) {
            _tend(launches[n - 1].game, caller);
            if (n > 1) {
                uint256 c = upkeepCursor % (n - 1);
                upkeepCursor = c + 1;
                _tend(launches[c].game, caller);
            }
            try IPadLiquidity(liquidity).distribute(2) {} catch {}
            try IPadLiquidity(liquidity).burnChunk() {} catch {}
        }
        locked = false;
    }

    function _tend(address game, address caller) internal {
        try IPadGame(game).upkeepStep(caller) {} catch {}
    }

    // ---- views -----------------------------------------------------------------------------------
    function genesisGraduated() public view returns (bool) {
        if (launches.length == 0) return false;
        IPadGame g = IPadGame(launches[0].game);
        return g.graduated() && !g.failed();
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function getLaunch(uint256 id) external view returns (Launch memory) {
        return launches[id - 1];
    }

    function gameOf(uint256 id) external view returns (address) {
        return launches[id - 1].game;
    }

    function tokenOf(uint256 id) external view returns (address) {
        return launches[id - 1].token;
    }

    function openDeadline() external view returns (uint256) {
        return deployedAt + OPEN_DELAY;
    }
}
