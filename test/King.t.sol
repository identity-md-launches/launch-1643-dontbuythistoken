// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {Rejector} from "./mocks/Mocks.sol";

contract KingTest is BaseTest {
    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    function test_firstBidMinimumAndFullSplit() public {
        vm.prank(players[0]);
        vm.expectRevert(bytes("min bid"));
        king.takeCrown{value: 0.009 ether}();
        uint256 devBefore = OWNER.balance;
        uint256 burnBefore = liq.burnBucket() + liq.totalBurnedEth();
        uint256 carryBefore = pad.carryPot();
        vm.prank(players[0]);
        king.takeCrown{value: 0.01 ether}();
        assertEq(king.king(), players[0]);
        assertEq(king.bid(), 0.01 ether);
        // whole first bid is "extra": 50% games (none live -> carry pot), 25% burn, 25% dev
        assertEq(pad.carryPot() - carryBefore, 0.005 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - burnBefore, 0.0025 ether);
        assertEq(OWNER.balance - devBefore, 0.0025 ether);
        assertEq(address(king).balance, 0, "the whole first bid is split away");
    }

    function test_challengeNeedsHoldAnd110Percent() public {
        vm.prank(players[0]);
        king.takeCrown{value: 0.01 ether}();
        vm.prank(players[1]);
        vm.expectRevert(bytes("king holds"));
        king.takeCrown{value: 0.02 ether}();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(players[1]);
        vm.expectRevert(bytes("bid too low"));
        king.takeCrown{value: 0.0109 ether}();
        uint256 p0 = players[0].balance;
        uint256 devBefore = OWNER.balance;
        uint256 carryBefore = pad.carryPot();
        uint256 burnBefore = liq.burnBucket() + liq.totalBurnedEth();
        vm.prank(players[1]);
        king.takeCrown{value: 0.02 ether}();
        assertEq(king.king(), players[1]);
        assertEq(players[0].balance - p0, 0.01 ether, "old king refunded in full");
        // extra = 0.01: 0.005 games (carry), 0.0025 burn, 0.0025 dev
        assertEq(pad.carryPot() - carryBefore, 0.005 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - burnBefore, 0.0025 ether);
        assertEq(OWNER.balance - devBefore, 0.0025 ether);
        assertEq(address(king).balance, 0, "refund and extra leave nothing behind");
        assertEq(king.nextMinBid(), 0.022 ether);
    }

    function test_extraFundsLiveGamesByPotSize() public {
        uint256 a = pad.launch("A", "A", "");
        PadGame ga = PadGame(pad.gameOf(a));
        uint256 b = pad.launch("B", "B", "");
        PadGame gb = PadGame(pad.gameOf(b));
        uint256 c = pad.launch("C", "C", "");
        PadGame gc = PadGame(pad.gameOf(c));
        mintAll(ga, 5);
        mintAll(gb, 5);
        mintAll(gc, 4); // fewer than 5 imps: excluded
        advance(10 minutes);
        rollAs(ga, players[0]);
        rollAs(ga, players[1]);
        rollAs(gb, players[2]);
        rollAs(gc, players[3]);
        assertTrue(!ga.ended() && !gb.ended() && !gc.ended());
        uint256 potA = ga.pot();
        uint256 potB = gb.pot();
        uint256 potC = gc.pot();
        assertGt(potA, potB);
        vm.prank(players[8]);
        king.takeCrown{value: 1 ether}();
        uint256 games = 0.5 ether;
        uint256 total = potA + potB;
        assertEq(ga.pot() - potA, games * potA / total);
        assertEq(gb.pot() - potB, games - games * potA / total);
        assertEq(gc.pot(), potC);
    }

    function test_refundToRejectingKingIsClaimable() public {
        Rejector rj = new Rejector();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        king.takeCrown{value: 0.01 ether}();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(players[1]);
        king.takeCrown{value: 0.02 ether}();
        assertEq(king.claimable(address(rj)), 0.01 ether);
        assertEq(address(king).balance, 0.01 ether, "claimable is backed");
        vm.prank(address(rj));
        vm.expectRevert(bytes("claim failed"));
        king.claim();
    }

    function test_distributeSendsPoolFeesToKing() public {
        vm.prank(players[0]);
        king.takeCrown{value: 0.01 ether}();
        // simulate trading fees on the PvP pool: 0.1 ETH and 1000 PVP
        vm.deal(address(pm), address(pm).balance + 0.1 ether);
        vm.prank(address(pm));
        pvpToken.transfer(address(pm), 0); // no-op, token already unlocked
        deal(address(pvpToken), address(pm), pvpToken.balanceOf(address(pm)) + 1000 ether);
        pm.creditFees(liq.poolKey(address(pvpToken)), 0.1 ether, 1000 ether);
        uint256 before = players[0].balance;
        king.distribute(1);
        uint256 got = players[0].balance - before;
        assertGt(got, 0.1 ether, "fees plus token sale proceeds");
        assertApproxEqAbs(liq.getPool(0).ethFees, 0.1 ether, 1e9);
        assertEq(liq.getPool(0).tokenFees, 1000 ether);
        assertEq(pvpToken.balanceOf(address(liq)), 0, "small amount fully sold");
    }

    function test_distributeWithoutKingEscrows() public {
        vm.deal(address(pm), address(pm).balance + 0.1 ether);
        pm.creditFees(liq.poolKey(address(pvpToken)), 0.1 ether, 0);
        liq.distribute(3);
        assertApproxEqAbs(liq.kingEscrow(), 0.1 ether, 1e9);
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}(); // upkeep distributes: escrow goes to the new king
        assertEq(liq.kingEscrow(), 0);
        assertApproxEqAbs(players[8].balance, 10 ether - 0.01 ether + 0.1 ether, 1e9);
    }

    function test_burnChunkBuysPvpToDeadEvery10Minutes() public {
        vm.deal(address(this), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes); // upkeep already burned the graduation dust
        uint256 burnedBefore = liq.totalBurnedEth();
        liq.fundBurn{value: 0.05 ether}();
        uint256 deadBefore = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0.03 ether, "max 0.02 per buy");
        assertGt(pvpToken.balanceOf(DEAD), deadBefore);
        assertEq(liq.totalBurnedEth() - burnedBefore, 0.02 ether);
        uint256 dead1 = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0.03 ether, "one buy per 10 min");
        assertEq(pvpToken.balanceOf(DEAD), dead1);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0.01 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0);
    }

    function test_burnWaitsForPvpGraduation() public {
        // fresh deployment where PvP has not graduated
        BaseTest.setUp();
        openPad();
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.05 ether}();
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0.05 ether);
        assertEq(liq.totalBurnedEth(), 0);
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(bytes("not pool manager"));
        liq.unlockCallback("");
    }

    function test_launchAfterGenesisPlaysAndGraduatesIntoOwnPool() public {
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        PadToken t = PadToken(pad.tokenOf(id));
        playOut(g, 6, 2);
        if (!g.graduated()) g.graduate();
        assertTrue(g.graduated());
        assertTrue(t.unlocked());
        assertEq(liq.poolCount(), 2);
        assertEq(liq.getPool(1).launchId, id);
        assertGt(liq.burnBucket(), 0, "non-genesis rolls fund the burn bucket");
    }
}
