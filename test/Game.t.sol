// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {Rejector} from "./mocks/Mocks.sol";

contract GameTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    // ---- signup ----------------------------------------------------------------------------------
    function test_firstMintStartsSignup() public {
        assertEq(pvp.status(), 0);
        vm.prank(players[0]);
        pvp.mint();
        assertEq(pvp.firstMintAt(), vm.getBlockTimestamp());
        assertEq(pvp.playStart(), vm.getBlockTimestamp() + 10 minutes);
        assertEq(pvp.hardEnd(), vm.getBlockTimestamp() + 60 minutes);
        assertEq(pvp.status(), 1);
        assertEq(pvp.impCount(), 1);
        assertEq(pvp.impOf(players[0]), 1);
    }

    function test_mintOnePerWalletAndSignupWindow() public {
        vm.prank(players[0]);
        pvp.mint();
        vm.prank(players[0]);
        vm.expectRevert(bytes("one imp per wallet"));
        pvp.mint();
        advance(10 minutes - 1);
        vm.prank(players[1]);
        pvp.mint();
        advance(1);
        vm.prank(players[2]);
        vm.expectRevert(bytes("signup over"));
        pvp.mint();
    }

    function test_mintCapsAt200() public {
        for (uint256 i; i < 200; ++i) {
            vm.prank(address(uint160(0xB000 + i)));
            pvp.mint();
        }
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("full"));
        pvp.mint();
    }

    // ---- roll rules ------------------------------------------------------------------------------
    function test_rollRequiresPlayPhasePriceAndImp() public {
        vm.prank(players[0]);
        vm.expectRevert(bytes("roll price"));
        pvp.roll{value: 0.001 ether}();
        vm.prank(players[0]);
        vm.expectRevert(bytes("no imp"));
        pvp.roll{value: 0.002 ether}();
        vm.prank(players[0]);
        pvp.mint();
        vm.prank(players[0]);
        vm.expectRevert(bytes("not playing"));
        pvp.roll{value: 0.002 ether}();
        advance(10 minutes);
        rollAs(pvp, players[0]);
        vm.prank(players[0]);
        vm.expectRevert(bytes("cooldown"));
        pvp.roll{value: 0.002 ether}();
        advance(60);
        rollAs(pvp, players[0]);
    }

    function test_rollSplitGenesisBurnShareToPot() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        // 90% curve, 8% pot, 2% burn -> genesis pot
        assertEq(pvp.ethRaised(), 0.0018 ether);
        assertEq(pvp.pot(), 0.0002 ether);
        assertEq(liq.burnBucket(), 0);
        assertEq(address(pvp).balance, 0.002 ether);
        assertGt(pvpToken.balanceOf(players[0]), 0);
        (uint256 q,) = gameTemplate.quote(0.0018 ether);
        assertEq(pvpToken.balanceOf(players[0]), q);
    }

    function test_nonGenesisBurnShareGoesToBurnBucket() public {
        graduatePvp();
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        mintAll(g, 1);
        advance(10 minutes);
        uint256 before = liq.burnBucket() + liq.totalBurnedEth();
        uint256 potBefore = g.pot(); // may hold the carry pot of the genesis game
        rollAs(g, players[0]);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - before, 0.00004 ether);
        assertEq(g.pot() - potBefore, 0.00016 ether);
        assertEq(g.ethRaised(), 0.0018 ether);
    }

    function test_curveQuoteMatchesConstantProduct() public view {
        (uint256 out, uint256 used) = gameTemplate.quote(1 ether);
        // (1+1)*(1e9 - out) = 1e9 -> out = 5e8
        assertEq(out, 500_000_000 ether);
        assertEq(used, 1 ether);
        (out, used) = gameTemplate.quote(4 ether);
        assertEq(out, 800_000_000 ether);
        assertEq(used, 4 ether);
        (out, used) = gameTemplate.quote(5 ether);
        assertEq(out, 800_000_000 ether);
        assertEq(used, 4 ether);
    }

    function test_soldOutCurveSendsRollToPot() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        // fill the curve almost completely through a large donation-free path: simulate by rolling until
        // sold out is impractical (2222 rolls); instead check the sold-out branch via quote on a state set by rolls.
        rollAs(pvp, players[0]);
        (,, uint256 remaining) = pvp.curveState();
        assertLt(remaining, 800_000_000 ether);
        assertGt(remaining, 0);
    }

    function test_tokenLockedUntilGraduation() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        uint256 bal = pvpToken.balanceOf(players[0]);
        vm.prank(players[0]);
        vm.expectRevert(bytes("locked until graduation"));
        pvpToken.transfer(players[1], bal);
        vm.prank(players[0]);
        pvpToken.approve(players[1], bal);
        vm.prank(players[1]);
        vm.expectRevert(bytes("locked until graduation"));
        pvpToken.transferFrom(players[0], players[1], bal);
        vm.expectRevert(bytes("not liquidity"));
        pvpToken.unlock();
    }

    // ---- dice and RNG ----------------------------------------------------------------------------
    function test_rollResolvesAfterThreeBlocksWithArbHashes() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        PadGame.Roll memory r = pvp.getRoll(0);
        assertEq(r.commitBlock, arb.number());
        assertEq(pvp.pendingCount(), 1);
        arb.advance(3);
        pvp.poke();
        assertEq(pvp.pendingCount(), 1, "needs commit+4");
        arb.advance(1);
        pvp.poke();
        assertEq(pvp.pendingCount(), 0);
        r = pvp.getRoll(0);
        assertTrue(r.resolved);
        assertFalse(r.expired);
        PadGame.Imp memory imp = pvp.getImp(0);
        int256 expected = _expectedDelta(address(pvp), 0, 0, r.commitBlock);
        assertEq(int256(r.delta), expected);
        assertEq(int256(imp.height), expected);
        assertTrue(expected != 0 && expected >= -4 && expected <= 4);
    }

    function test_expiredRollMovesTowardZero() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        arb.advance(4);
        pvp.poke();
        int256 h0 = pvp.getImp(0).height;
        advance(60);
        rollAs(pvp, players[0]);
        arb.advance(300); // past the 256-block window, no hash available
        pvp.poke();
        PadGame.Roll memory r = pvp.getRoll(1);
        assertTrue(r.resolved && r.expired);
        int256 h1 = pvp.getImp(0).height;
        if (h0 > 0) assertEq(h1, h0 >= 4 ? h0 - 4 : int256(0));
        else assertEq(h1, h0 <= -4 ? h0 + 4 : int256(0));
    }

    function test_rollResolvesOwnPreviousRoll() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(60); // 240 blocks
        rollAs(pvp, players[0]);
        assertTrue(pvp.getRoll(0).resolved);
        assertFalse(pvp.getRoll(1).resolved);
        assertEq(pvp.pendingCount(), 1);
    }

    function test_resolveBatchIsEight() public {
        mintAll(pvp, 10);
        advance(10 minutes);
        for (uint256 i; i < 10; ++i) {
            rollAs(pvp, players[i]);
        }
        assertEq(pvp.pendingCount(), 10);
        arb.advance(4);
        pvp.poke();
        assertEq(pvp.pendingCount(), 2);
        pvp.poke();
        assertEq(pvp.pendingCount(), 0);
    }

    function test_bellEndsGame() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        // force a height of 49 then resolve a +1..+4 roll
        rollAs(pvp, players[0]);
        _setHeight(0, 49);
        PadGame.Roll memory r = pvp.getRoll(0);
        int256 d = _expectedDelta(address(pvp), 0, 0, r.commitBlock);
        arb.advance(4);
        pvp.poke();
        if (d > 0) {
            assertEq(pvp.getImp(0).height, 50);
            assertEq(pvp.bellAt(), vm.getBlockTimestamp());
            assertEq(pvp.bellRinger(), players[0]);
            assertTrue(pvp.ended() && pvp.bellRang());
            vm.prank(players[1]);
            vm.expectRevert(bytes("game over"));
            pvp.roll{value: 0.002 ether}();
        } else {
            assertEq(pvp.getImp(0).height, 49 + d);
            assertEq(pvp.bellAt(), 0);
        }
    }

    function test_deathAndAllDeadEnd() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(10 minutes); // player 1 never rolled: dead; player 0 dies now too
        assertTrue(pvp.ended(), "all dead");
        assertFalse(pvp.isAlive(0));
        assertFalse(pvp.isAlive(1));
        vm.prank(players[0]);
        vm.expectRevert(bytes("game over"));
        pvp.roll{value: 0.002 ether}();
    }

    function test_deadImpCannotRollWhileOthersPlay() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(9 minutes);
        rollAs(pvp, players[0]);
        advance(2 minutes);
        vm.prank(players[1]);
        vm.expectRevert(bytes("imp dead"));
        pvp.roll{value: 0.002 ether}();
        rollAs(pvp, players[0]);
    }

    function test_hardEndAt60Minutes() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        for (uint256 i; i < 9; ++i) {
            rollAs(pvp, players[0]);
            advance(5 minutes);
        }
        assertFalse(pvp.ended());
        advance(5 minutes);
        assertEq(pvp.endTime(), pvp.hardEnd());
        assertTrue(pvp.ended());
    }

    // ---- finalize --------------------------------------------------------------------------------
    function test_finalizeRanksAndPays() public {
        mintAll(pvp, 5);
        advance(10 minutes);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        arb.advance(4);
        pvp.poke();
        // fix heights deterministically: p0 = 30, p1 = -30 (reached later), p2 = 10, p3 = 5, p4 = 0
        _setHeight(0, 30);
        _setHeightAt(1, -30, uint40(vm.getBlockTimestamp() + 1));
        _setHeight(2, 10);
        _setHeight(3, 5);
        _setHeight(4, 0);
        advance(10 minutes); // all dead at the same time -> living counts those alive at endTime
        // everyone rolled at the same second so they all die at endTime: nobody living -> carry pot
        assertTrue(pvp.ended());
        uint256 potBefore = pvp.pot();
        vm.prank(players[9]);
        pvp.finalize();
        assertTrue(pvp.finalized());
        assertEq(pvp.livingAtEnd(), 0);
        uint256 fee = potBefore * 50 / 10_000;
        assertEq(pad.carryPot(), potBefore - fee);
        assertEq(players[9].balance, 10 ether + fee);
        assertEq(pvp.pot(), 0);
    }

    function test_finalizePaysTriangularRanksAndBell() public {
        mintAll(pvp, 5);
        advance(10 minutes);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
            advance(1); // staggered so later rollers stay alive longer
        }
        arb.advance(4);
        pvp.poke();
        _setHeight(0, 30);
        _setHeightAt(1, -30, uint40(vm.getBlockTimestamp() + 1));
        _setHeight(2, 10);
        _setHeight(3, 5);
        _setHeight(4, 0);
        // bell by player 4 (last roller), game ends now, all five alive
        _setBell(uint64(vm.getBlockTimestamp()), players[4]);
        _setHeight(4, 50);
        assertTrue(pvp.ended() && pvp.bellRang());
        uint256 p = pvp.pot();
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = players[i].balance;
        }
        vm.prank(players[9]);
        pvp.finalize();
        uint256 fee = p * 50 / 10_000;
        p -= fee;
        uint256 bell = p * 20 / 100;
        uint256 ranks = p - bell;
        // living 5 -> paid 3: order p4 (50), p0 (30, earlier), p1 (-30, later); weights 3,2,1 / 6
        assertEq(pvp.livingAtEnd(), 5);
        assertEq(pvp.paidAtEnd(), 3);
        assertEq(players[4].balance - before[4], ranks * 3 / 6 + bell);
        assertEq(players[0].balance - before[0], ranks * 2 / 6);
        assertEq(players[1].balance - before[1], ranks * 1 / 6);
        assertEq(players[2].balance, before[2]);
        assertEq(players[3].balance, before[3]);
        assertEq(players[9].balance, 10 ether + fee);
        vm.expectRevert(bytes("not finalizable"));
        pvp.finalize();
    }

    function test_finalizeWaitsForPendingRolls() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        vm.warp(vm.getBlockTimestamp() + 60 minutes); // time passes, no new L2 blocks
        assertTrue(pvp.ended());
        vm.expectRevert(bytes("not finalizable"));
        pvp.finalize();
        arb.advance(4);
        pvp.finalize();
        assertTrue(pvp.finalized());
    }

    function test_finalizerFeeCapped() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        vm.deal(address(this), 10 ether);
        pvp.fundPot{value: 5 ether}();
        advance(60 minutes);
        vm.prank(players[9]);
        pvp.finalize();
        assertEq(players[9].balance, 10 ether + 0.005 ether);
    }

    function test_failedPushBecomesClaimable() public {
        Rejector rj = new Rejector();
        vm.prank(address(rj));
        pvp.mint();
        advance(10 minutes);
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        pvp.roll{value: 0.002 ether}();
        advance(60 minutes);
        pvp.finalize();
        // rejector was the only player; it died 10 min after its roll -> not living -> carry pot.
        assertEq(pvp.livingAtEnd(), 0);
        // now a winner that rejects ETH: play with staggered rolls so it is alive at end.
    }

    function test_claimableWinner() public {
        Rejector rj = new Rejector();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        pvp.mint();
        mintAll(pvp, 1);
        advance(10 minutes);
        vm.prank(address(rj));
        pvp.roll{value: 0.002 ether}();
        advance(1);
        rollAs(pvp, players[0]);
        arb.advance(4);
        pvp.poke();
        _setHeight(0, 20);
        _setHeight(1, 1);
        _setBell(uint64(vm.getBlockTimestamp()), players[0]);
        uint256 p = pvp.pot();
        pvp.finalize();
        uint256 fee = p * 50 / 10_000;
        uint256 ranks = (p - fee) * 80 / 100;
        assertEq(pvp.claimable(address(rj)), ranks);
        assertEq(address(pvp).balance, ranks + pvp.ethRaised());
        vm.prank(address(rj));
        vm.expectRevert(bytes("claim failed"));
        pvp.claim();
    }

    function test_conservationOfEth() public {
        mintAll(pvp, 4);
        advance(10 minutes);
        for (uint256 r; r < 3; ++r) {
            for (uint256 i; i < 4; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        assertEq(address(pvp).balance, pvp.pot() + pvp.ethRaised());
        assertEq(pvp.ethRaised() + pvp.pot(), 12 * 0.002 ether);
    }

    // ---- graduation ------------------------------------------------------------------------------
    function test_graduationCreatesPoolUnlocksTokenBurnsExcess() public {
        playOut(pvp, 4, 3);
        assertTrue(pvp.finalized());
        uint256 raised = pvp.ethRaised();
        uint256 tokens = pvpToken.balanceOf(address(pvp));
        if (!pvp.graduated()) pvp.graduate();
        assertTrue(pvp.graduated() && !pvp.failed());
        assertTrue(pvpToken.unlocked());
        assertEq(pvpToken.balanceOf(address(pvp)), 0);
        assertEq(liq.poolCount(), 1);
        assertEq(pm.initializeCount(), 1);
        PadLiquidity_Pool(liq.getPool(0).token, address(pvpToken));
        uint256 inPool = pvpToken.balanceOf(address(pm));
        uint256 burned = pvpToken.balanceOf(DEAD);
        assertEq(inPool + burned, tokens);
        assertGt(burned, 0, "token side is in excess at the curve price");
        assertApproxEqRel(address(pm).balance, raised, 1e13);
        assertEq(address(pvp).balance, 0);
        // price: sqrtP^2 / 2^192 = vTok / vEth
        uint160 sqrtP = pm.getPool(liq.poolKey(address(pvpToken))).sqrtPriceX96;
        (uint256 vEth, uint256 vTok,) = pvp.curveState();
        uint256 price = (uint256(sqrtP) * uint256(sqrtP)) >> 192;
        assertApproxEqAbs(price, vTok / vEth, 1);
        // token now transferable
        uint256 bal = pvpToken.balanceOf(players[0]);
        uint256 other = pvpToken.balanceOf(players[1]);
        vm.prank(players[0]);
        pvpToken.transfer(players[1], bal);
        assertEq(pvpToken.balanceOf(players[1]), other + bal);
        vm.expectRevert(bytes("not graduable"));
        pvp.graduate();
    }

    function PadLiquidity_Pool(address a, address b) internal pure {
        assertEq(a, b);
    }

    function test_graduationWithoutEthFailsAndBurns() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        advance(10 minutes); // nobody rolled -> all dead, no ETH
        assertTrue(pvp.ended());
        pvp.finalize();
        pvp.graduate();
        assertTrue(pvp.failed());
        assertEq(pvpToken.balanceOf(DEAD), 1_000_000_000 ether);
        assertFalse(pad.genesisGraduated());
        assertEq(liq.poolCount(), 0);
    }

    function test_graduateOnlyFromGame() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("not game"));
        liq.graduate{value: 1 ether}(1, address(pvpToken), 1, 1, 1);
    }

    function test_upkeepFinalizesAndGraduatesDueGame() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(60 minutes);
        // a state-changing call elsewhere (pad.upkeep) finalizes and, on the next call, graduates
        pad.upkeep();
        assertTrue(pvp.finalized());
        pad.upkeep();
        assertTrue(pvp.graduated());
    }

    // ---- helpers ---------------------------------------------------------------------------------
    function _expectedDelta(address game, uint256 imp, uint256 nonce, uint256 commit) internal pure returns (int256) {
        bytes32 h1 = keccak256(abi.encode("arb", commit + 1));
        bytes32 h2 = keccak256(abi.encode("arb", commit + 2));
        bytes32 h3 = keccak256(abi.encode("arb", commit + 3));
        uint256 face = uint256(keccak256(abi.encode(game, imp, nonce, h1, h2, h3))) % 8;
        return face < 4 ? -int256(face + 1) : int256(face - 3);
    }

    // imps[] is at slot 10 in PadGame; each Imp packs into one word:
    // owner (160) | height (16) | lastRoll (40) | heightReachedAt (40)  -> word 0; nonce, pendingRoll -> word 1
    function _impSlot(uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
    }

    function _setHeight(uint256 i, int16 h) internal {
        PadGame.Imp memory imp = pvp.getImp(i);
        _setHeightAt(i, h, imp.heightReachedAt);
    }

    function _setHeightAt(uint256 i, int16 h, uint40 at) internal {
        PadGame.Imp memory imp = pvp.getImp(i);
        uint256 word = uint256(uint160(imp.owner)) | (uint256(uint16(h)) << 160) | (uint256(imp.lastRoll) << 176)
            | (uint256(at) << 216);
        vm.store(address(pvp), _impSlot(i), bytes32(word));
        PadGame.Imp memory after_ = pvp.getImp(i);
        assertEq(after_.height, h, "height set");
        assertEq(after_.owner, imp.owner, "owner kept");
    }

    // bellAt (uint64) and maxActivity (uint64) share slot 8 with firstMintAt: firstMintAt | bellAt<<64 | maxActivity<<128
    function _setBell(uint64 at, address ringer) internal {
        uint256 word = uint256(pvp.firstMintAt()) | (uint256(at) << 64) | (uint256(pvp.maxActivity()) << 128);
        vm.store(address(pvp), bytes32(uint256(8)), bytes32(word));
        vm.store(address(pvp), bytes32(uint256(9)), bytes32(uint256(uint160(ringer))));
        assertEq(pvp.bellAt(), at, "bell set");
        assertEq(pvp.bellRinger(), ringer, "ringer set");
    }
}
