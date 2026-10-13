// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, OneShotDeployer} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadHook} from "../src/PadHook.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";

contract PadTest is BaseTest {
    // ---- deployment ------------------------------------------------------------------------------
    function test_deployGasUnderBudget() public view {
        assertLt(deployer.gasUsed(), 13_000_000, "deploy gas target");
        assertLt(deployer.gasUsed(), 16_777_216, "deploy gas hard cap");
    }

    function test_runtimeSizesAndNoEscapeOpcodes() public view {
        address[5] memory apps =
            [address(tokenTemplate), address(gameTemplate), address(pad), address(liq), address(king)];
        for (uint256 i; i < 5; ++i) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576, "EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function test_bindingsAndOwner() public view {
        assertEq(pad.owner(), OWNER);
        assertEq(king.owner(), OWNER);
        assertEq(king.dev(), OWNER);
        assertEq(pad.liquidity(), address(liq));
        assertEq(pad.king(), address(king));
        assertEq(liq.king(), address(king));
        assertEq(pad.launchCount(), 1);
        assertEq(pvpToken.name(), "Pepes Value Pepes");
        assertEq(pvpToken.symbol(), "PVP");
        assertEq(pvpToken.balanceOf(address(pvp)), 1_000_000_000 ether);
        assertTrue(pvp.genesis());
        assertFalse(pad.opened());
    }

    function test_bindingsAreOneShot() public {
        vm.expectRevert(bytes("bound"));
        pad.bindLiquidity();
        vm.expectRevert(bytes("bound"));
        pad.startGenesis();
        vm.expectRevert(bytes("bound"));
        liq.bindKing();
    }

    function test_templatesCannotBeInitialized() public {
        vm.expectRevert(bytes("initialized"));
        tokenTemplate.initialize("x", "y", address(1), address(2));
        vm.expectRevert(bytes("initialized"));
        gameTemplate.initialize(1, address(1), address(2), false);
        vm.expectRevert(bytes("initialized"));
        pvpToken.initialize("x", "y", address(1), address(2));
        vm.expectRevert(bytes("initialized"));
        pvp.initialize(1, address(1), address(2), false);
    }

    // ---- open switch -----------------------------------------------------------------------------
    function test_closedPadRevertsEverything() public {
        vm.prank(players[0]);
        vm.expectRevert(bytes("pad not open"));
        pvp.mint();
        vm.prank(players[0]);
        vm.expectRevert(bytes("pad not open"));
        pvp.roll{value: 0.002 ether}();
        vm.expectRevert(bytes("pad not open"));
        pad.launch("a", "b", "");
        vm.expectRevert(bytes("king not open"));
        king.takeCrown{value: 1 ether}();
    }

    function test_openPadByOwnerDeploysHookWithExactFlag() public {
        bytes32 salt = mineSalt();
        address predicted = liq.hookAddressFor(salt);
        vm.prank(OWNER);
        pad.openPad(salt);
        assertTrue(pad.opened());
        assertEq(pad.hook(), predicted);
        assertEq(liq.hook(), predicted);
        assertEq(uint160(predicted) & 0x3FFF, 0x2000);
        assertEq(PadHook(predicted).liquidity(), address(liq));
        assertEq(PadHook(predicted).poolManager(), address(pm));
    }

    function test_openPadRejectsBadSalt() public {
        bytes32 bad;
        for (uint256 i; i < 100; ++i) {
            if (uint160(liq.hookAddressFor(bytes32(i))) & 0x3FFF != 0x2000) {
                bad = bytes32(i);
                break;
            }
        }
        vm.prank(OWNER);
        vm.expectRevert(bytes("hook flags"));
        pad.openPad(bad);
        assertFalse(pad.opened());
    }

    function test_openPadStrangerBefore30DaysReverts() public {
        bytes32 salt = mineSalt();
        vm.prank(players[0]);
        vm.expectRevert(bytes("not yet"));
        pad.openPad(salt);
        vm.warp(pad.openDeadline() - 1);
        vm.prank(players[0]);
        vm.expectRevert(bytes("not yet"));
        pad.openPad(salt);
    }

    function test_openPadByAnyoneAfter30Days() public {
        bytes32 salt = mineSalt();
        vm.warp(pad.openDeadline());
        vm.prank(players[0]);
        pad.openPad(salt);
        assertTrue(pad.opened());
    }

    function test_openPadOnlyOnce() public {
        openPad();
        vm.prank(OWNER);
        vm.expectRevert(bytes("opened"));
        pad.openPad(bytes32(uint256(1)));
    }

    function test_deployHookOnlyByPad() public {
        vm.expectRevert(bytes("not pad"));
        liq.deployHook(bytes32(0));
    }

    // ---- hook ------------------------------------------------------------------------------------
    function test_hookRejectsForeignInitialize() public {
        openPad();
        PadHook h = PadHook(pad.hook());
        PoolKey memory key = PoolKey(address(0), address(pvpToken), 10_000, 200, address(h));
        vm.prank(address(pm));
        vm.expectRevert(bytes("only PadLiquidity"));
        h.beforeInitialize(players[0], key, 1 << 96);
        vm.prank(players[0]);
        vm.expectRevert(bytes("not pool manager"));
        h.beforeInitialize(address(liq), key, 1 << 96);
        vm.prank(address(pm));
        assertEq(h.beforeInitialize(address(liq), key, 1 << 96), PadHook.beforeInitialize.selector);
        // through the manager: a stranger cannot initialize a pool with the hook
        vm.prank(players[0]);
        vm.expectRevert(bytes("only PadLiquidity"));
        pm.initialize(key, 1 << 96);
    }

    // ---- genesis gating -------------------------------------------------------------------------
    function test_launchRevertsUntilGenesisGraduates() public {
        openPad();
        vm.prank(players[0]);
        vm.expectRevert(bytes("genesis not graduated"));
        pad.launch("Foo", "FOO", "");
        vm.expectRevert(bytes("king not open"));
        king.takeCrown{value: 1 ether}();
        graduatePvp();
        vm.prank(players[0]);
        uint256 id = pad.launch("Foo", "FOO", "https://example.com/foo.png");
        assertEq(id, 2);
        PvPPad.Launch memory l = pad.getLaunch(2);
        assertEq(l.creator, players[0]);
        assertEq(PadToken(l.token).symbol(), "FOO");
        assertEq(PadGame(l.game).launchId(), 2);
        assertFalse(PadGame(l.game).genesis());
    }

    function test_failedGenesisIsRestartedByLaunchAndThePadRecovers() public {
        openPad();
        // a stranger mints one free Imp, then nobody rolls: the genesis game fails
        vm.prank(address(0xBAD));
        pvp.mint();
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        pvp.poke();
        pvp.poke();
        assertTrue(pvp.failed());
        assertTrue(pad.genesisFailed());
        assertFalse(pad.genesisGraduated());
        vm.expectRevert(bytes("king not open"));
        king.takeCrown{value: 0.01 ether}();
        // launch() relaunches PvP instead of creating "Next"
        vm.prank(players[0]);
        uint256 id = pad.launch("Next", "NXT", "");
        assertEq(id, 2);
        assertEq(pad.genesisId(), 2);
        assertEq(pad.launchCount(), 2);
        PvPPad.Launch memory l = pad.getLaunch(2);
        assertEq(l.name, "Pepes Value Pepes");
        assertEq(PadToken(l.token).symbol(), "PVP");
        assertTrue(PadGame(l.game).genesis());
        assertFalse(pad.genesisFailed());
        // the new genesis gates everything again until it graduates
        vm.expectRevert(bytes("genesis not graduated"));
        pad.launch("Next", "NXT", "");
        vm.expectRevert(bytes("genesis not failed"));
        pad.restartGenesis();
        PadGame pvp2 = PadGame(l.game);
        playOut(pvp2, 4, 3);
        if (!pvp2.graduated()) pvp2.graduate();
        assertTrue(pad.genesisGraduated());
        // now ordinary launches, the king and the burn (on the new PVP pool) work
        vm.prank(players[0]);
        uint256 id3 = pad.launch("Next", "NXT", "");
        assertEq(id3, 3);
        assertEq(pad.getLaunch(3).name, "Next");
        vm.prank(players[1]);
        king.takeCrown{value: 0.01 ether}();
        assertEq(liq.poolIndexOf(2), 1, "PVP #2 has the pool");
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 burnedBefore = liq.totalBurnedEth();
        liq.burnChunk();
        assertGt(liq.totalBurnedEth(), burnedBefore, "burn buys the new PVP");
        assertGt(PadToken(l.token).balanceOf(DEAD), 0);
    }

    function test_restartGenesisRevertsWhileGenesisWaitsOrPlays() public {
        vm.expectRevert(bytes("pad not open"));
        pad.restartGenesis();
        openPad();
        vm.expectRevert(bytes("genesis not failed"));
        pad.restartGenesis();
        vm.prank(players[0]);
        pvp.mint();
        vm.expectRevert(bytes("genesis not failed"));
        pad.restartGenesis();
    }

    function test_launchValidatesStrings() public {
        graduatePvp();
        vm.expectRevert(bytes("name"));
        pad.launch("123456789012345678901234567890123", "FOO", "");
        vm.expectRevert(bytes("ticker"));
        pad.launch("Foo", "12345678901", "");
        bytes memory url = new bytes(201);
        vm.expectRevert(bytes("url"));
        pad.launch("Foo", "FOO", string(url));
        vm.expectRevert(bytes("name"));
        pad.launch("", "FOO", "");
    }

    function test_carryPotFundsNextLaunch() public {
        graduatePvp();
        vm.deal(address(this), 1 ether);
        uint256 carryBefore = pad.carryPot();
        pad.fundCarry{value: 0.3 ether}();
        assertEq(pad.carryPot(), carryBefore + 0.3 ether);
        uint256 id = pad.launch("Foo", "FOO", "");
        assertEq(pad.carryPot(), 0);
        assertEq(PadGame(pad.gameOf(id)).pot(), carryBefore + 0.3 ether);
    }

    function test_upkeepForOnlyGames() public {
        vm.expectRevert(bytes("not game"));
        pad.upkeepFor(players[0]);
        vm.expectRevert(bytes("not pad"));
        pvp.upkeepStep(players[0]);
        pad.upkeep(); // permissionless, no-op before open
    }

    function test_fundGamesOnlyKing() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("not king"));
        pad.fundGames{value: 1 ether}();
    }
}
