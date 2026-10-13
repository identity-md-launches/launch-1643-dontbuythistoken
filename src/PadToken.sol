// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PadToken
/// @notice ERC-20 template cloned (EIP-1167) by PvPPad for every launch. Fixed 1e9 supply, 18 decimals,
/// minted in full to the launch's game. Transfers are locked until graduation except when the sender is
/// the game or PadLiquidity. Unlock happens inside the graduation transaction, by PadLiquidity.
contract PadToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public game;
    address public liquidity;
    bool public unlocked;
    bool private initialized;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Initialized(address indexed game, address indexed liquidity, string name, string symbol);
    event Unlocked();

    /// @dev The template itself is never usable: it is marked initialized at deployment.
    constructor() {
        initialized = true;
    }

    function initialize(string calldata name_, string calldata symbol_, address game_, address liquidity_) external {
        require(!initialized, "initialized");
        initialized = true;
        name = name_;
        symbol = symbol_;
        game = game_;
        liquidity = liquidity_;
        totalSupply = SUPPLY;
        balanceOf[game_] = SUPPLY;
        emit Transfer(address(0), game_, SUPPLY);
        emit Initialized(game_, liquidity_, name_, symbol_);
    }

    function unlock() external {
        require(msg.sender == liquidity, "not liquidity");
        if (!unlocked) {
            unlocked = true;
            emit Unlocked();
        }
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(unlocked || msg.sender == game || msg.sender == liquidity, "locked until graduation");
        require(to != address(0), "zero to");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
