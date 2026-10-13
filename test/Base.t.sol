// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadHook} from "../src/PadHook.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {MockArbSys, MockPoolManager, Rejector} from "./mocks/Mocks.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";

/// @notice Deploys the five manifest contracts in order inside one call, as the factory does.
contract OneShotDeployer {
    PadToken public token;
    PadGame public game;
    PvPPad public pad;
    PadLiquidity public liquidity;
    KingOfThePad public king;
    uint256 public gasUsed;

    function deployAll(address owner, address poolManager) external {
        uint256 g = gasleft();
        token = new PadToken();
        game = new PadGame();
        pad = new PvPPad(owner, address(token), address(game));
        liquidity = new PadLiquidity(poolManager, address(pad));
        king = new KingOfThePad(address(pad), address(liquidity), owner);
        gasUsed = g - gasleft();
    }
}

abstract contract BaseTest is Test {
    address constant OWNER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address constant ARB_ADDR = address(0x64);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockArbSys arb;
    MockPoolManager pm;
    OneShotDeployer deployer;
    PadToken tokenTemplate;
    PadGame gameTemplate;
    PvPPad pad;
    PadLiquidity liq;
    KingOfThePad king;
    PadGame pvp;
    PadToken pvpToken;

    address[] players;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        MockArbSys impl = new MockArbSys();
        vm.etch(ARB_ADDR, address(impl).code);
        arb = MockArbSys(ARB_ADDR);
        arb.set(1000);
        pm = new MockPoolManager();
        deployer = new OneShotDeployer();
        deployer.deployAll(OWNER, address(pm));
        tokenTemplate = deployer.token();
        gameTemplate = deployer.game();
        pad = deployer.pad();
        liq = deployer.liquidity();
        king = deployer.king();
        pvp = PadGame(pad.gameOf(1));
        pvpToken = PadToken(pad.tokenOf(1));
        for (uint256 i; i < 12; ++i) {
            address p = address(uint160(0xA000 + i));
            players.push(p);
            vm.deal(p, 10 ether);
        }
    }

    // ---- helpers ---------------------------------------------------------------------------------
    function mineSalt() internal view returns (bytes32 salt) {
        bytes32 h = liq.hookInitCodeHash();
        address deployerAddr = address(liq);
        bytes memory buf = abi.encodePacked(bytes1(0xff), deployerAddr, bytes32(0), h);
        for (uint256 i; i < 200_000; ++i) {
            uint256 a;
            assembly ("memory-safe") {
                mstore(add(buf, 53), i)
                a := and(keccak256(add(buf, 32), 85), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if (a & 0x3FFF == 0x2000) {
                salt = bytes32(i);
                assertEq(liq.hookAddressFor(salt), address(uint160(a)));
                return salt;
            }
        }
        revert("no salt");
    }

    function openPad() internal {
        bytes32 salt = mineSalt();
        vm.prank(OWNER);
        pad.openPad(salt);
    }

    function mintAll(PadGame g, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(players[i]);
            g.mint();
        }
    }

    /// @dev Advance time and L2 blocks together (4 blocks per second, like Arbitrum).
    function advance(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        arb.advance(secs * 4);
    }

    function rollAs(PadGame g, address who) internal {
        vm.prank(who);
        g.roll{value: 0.002 ether}();
    }

    /// @dev Signup, then every player rolls once per minute until the game ends by time, and finalizes.
    function playOut(PadGame g, uint256 n, uint256 rounds) internal {
        mintAll(g, n);
        advance(10 minutes);
        for (uint256 r; r < rounds; ++r) {
            for (uint256 i; i < n; ++i) {
                if (g.ended()) break;
                rollAs(g, players[i]);
            }
            advance(61);
        }
        while (!g.ended()) advance(60);
        advance(5);
        g.poke();
        if (!g.finalized()) g.finalize();
    }

    receive() external payable {}

    function graduatePvp() internal {
        if (!pad.opened()) openPad();
        playOut(pvp, 4, 3);
        if (!pvp.graduated()) pvp.graduate();
        assertTrue(pad.genesisGraduated(), "pvp graduated");
    }
}
