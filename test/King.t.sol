// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {Rejector, MockPoolManager} from "./mocks/Mocks.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../src/interfaces/Interfaces.sol";
import {PvPPad} from "../src/PvPPad.sol";

/// @notice Attacker that buys PVP, triggers the protocol's burn chunk, then sells back, all in one call.
contract Sandwicher is IUnlockCallback {
    MockPoolManager immutable pm;
    PvPPad immutable pad;
    PadToken immutable token;
    PoolKey key;

    constructor(MockPoolManager pm_, PvPPad pad_, PadToken token_, PoolKey memory key_) {
        pm = pm_;
        pad = pad_;
        token = token_;
        key = key_;
    }

    function attack(uint256 ethIn) external {
        pm.unlock(abi.encode(true, ethIn));
        pad.upkeep();
        pm.unlock(abi.encode(false, token.balanceOf(address(this))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool zeroForOne, uint256 amountIn) = abi.decode(data, (bool, uint256));
        int256 d = pm.swap(
            key, SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? 4_295_128_741 : type(uint160).max - 1), ""
        );
        int128 a0 = int128(d >> 128);
        int128 a1 = int128(d);
        if (zeroForOne) {
            pm.settle{value: uint256(uint128(-a0))}();
            pm.take(key.currency1, address(this), uint256(uint128(a1)));
        } else {
            pm.sync(key.currency1);
            token.transfer(address(pm), uint256(uint128(-a1)));
            pm.settle();
            pm.take(address(0), address(this), uint256(uint128(a0)));
        }
        return "";
    }

    receive() external payable {}
}

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
        // A received the genesis carry at creation: the weight is the roll-earned pot, not the total
        assertGt(ga.fundedPot(), 0);
        uint256 rollA = ga.rollPot();
        uint256 rollB = gb.rollPot();
        assertGt(rollA, rollB);
        vm.prank(players[8]);
        king.takeCrown{value: 1 ether}();
        uint256 games = 0.5 ether;
        uint256 total = rollA + rollB;
        assertEq(ga.pot() - potA, games * rollA / total);
        assertEq(gb.pot() - potB, games - games * rollA / total);
        assertEq(gc.pot(), potC);
        assertEq(ga.rollPot(), rollA, "king share is funded, not roll-earned");
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

    /// @dev Deepen the PVP pool so a 0.02 ETH chunk moves the price by far less than 1%.
    function deepenPvpPool(uint256 r0) internal {
        PoolKey memory key = liq.poolKey(address(pvpToken));
        MockPoolManager.PoolState memory ps = pm.getPool(key);
        uint256 r1 = ps.reserve1 * r0 / ps.reserve0;
        vm.deal(address(pm), address(pm).balance + r0);
        deal(address(pvpToken), address(pm), pvpToken.balanceOf(address(pm)) + r1);
        pm.fatten(key, r0, r1);
    }

    function test_burnChunkBuysPvpToDeadEvery10Minutes() public {
        deepenPvpPool(20 ether);
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

    function test_burnChunkStopsAtOnePercentPriceMoveAndKeepsTheRest() public {
        // thin pool (genesis raised about 0.02 ETH): a 0.02 ETH chunk would nearly double the price
        PoolKey memory key = liq.poolKey(address(pvpToken));
        uint160 before = liq.sqrtPriceOf(key);
        assertEq(before, pm.getPool(key).sqrtPriceX96, "extsload reads slot0");
        vm.deal(address(this), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.fundBurn{value: 0.02 ether}();
        uint256 bucket = liq.burnBucket();
        uint256 burnedBefore = liq.totalBurnedEth();
        liq.burnChunk();
        uint256 spent = liq.totalBurnedEth() - burnedBefore;
        assertGt(spent, 0, "a partial buy happened");
        assertLt(spent, 0.002 ether, "the thin pool caps the fill");
        assertEq(liq.burnBucket(), bucket - spent, "unspent ETH stays in the bucket");
        uint160 after_ = liq.sqrtPriceOf(key);
        assertLt(after_, before);
        assertGe(uint256(after_) * 10_000, uint256(before) * 9_950, "sqrt price moved at most 0.5%");
    }

    function test_sandwichOnBurnChunkDoesNotPay() public {
        PoolKey memory key = liq.poolKey(address(pvpToken));
        Sandwicher atk = new Sandwicher(pm, pad, pvpToken, key);
        vm.deal(address(atk), 1 ether);
        vm.deal(address(this), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.fundBurn{value: 0.02 ether}();
        uint256 burnedBefore = liq.totalBurnedEth();
        atk.attack(0.01 ether);
        assertGt(liq.totalBurnedEth(), burnedBefore, "the chunk ran inside the sandwich");
        assertLt(address(atk).balance, 1 ether, "the attacker loses the pool fees on the round trip");
        assertEq(pvpToken.balanceOf(address(atk)), 0);
    }

    function test_takeCrownUpkeepPaysFinalizerFeeToBidder() public {
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        mintAll(g, 3);
        advance(10 minutes);
        for (uint256 i; i < 3; ++i) {
            rollAs(g, players[i]);
        }
        advance(60 minutes);
        assertTrue(g.ended() && !g.finalized());
        uint256 fee = g.pot() * 50 / 10_000;
        assertGt(fee, 0);
        uint256 before = players[7].balance;
        vm.prank(players[7]);
        king.takeCrown{value: 0.01 ether}();
        assertTrue(g.finalized(), "upkeep finalized the due game");
        assertEq(g.claimable(address(king)), 0, "nothing stranded on the king contract");
        // the bidder also receives, as the new king, the LP fees that the same upkeep distributed
        assertGe(players[7].balance, before - 0.01 ether + fee, "the bidder gets the finalizer fee");
    }

    function test_upkeepForAcceptsKingContract() public {
        vm.prank(address(king));
        pad.upkeepFor(players[0]);
        vm.expectRevert(bytes("not game"));
        pad.upkeepFor(players[0]);
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
