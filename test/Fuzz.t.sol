// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";

/// @notice Stateless property tests over the arithmetic: curve quotes, roll split, king split and
/// payout weights, each driven through the real contracts rather than a re-implementation.
contract FuzzTest is BaseTest {
    uint256 constant K = 1 ether * 1_000_000_000 ether;
    uint256 constant VTOK = 1_000_000_000 ether;
    uint256 constant CURVE_SUPPLY = 800_000_000 ether;

    // ---- curve --------------------------------------------------------------------------------
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteFromFreshCurveNeverUndercharges(uint256 ethIn) public view {
        ethIn = bound(ethIn, 0, 100 ether);
        (uint256 out, uint256 used) = gameTemplate.quote(ethIn);
        assertLe(out, CURVE_SUPPLY);
        assertLe(used, ethIn);
        assertGe((1 ether + used) * (VTOK - out), K, "product never below K");
        if (out < CURVE_SUPPLY) assertEq(used, ethIn, "all ETH used until sold out");
        else assertEq(used, 4 ether, "sold out costs exactly 4 ETH");
        if (ethIn >= 4 ether) assertEq(out, CURVE_SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteFromAnyCurveStateIsConsistent(uint256 sold, uint256 ethIn) public {
        sold = bound(sold, 0, CURVE_SUPPLY);
        ethIn = bound(ethIn, 0, 5 ether);
        _setCurve(gameTemplate, sold);
        (uint256 vEth, uint256 vTok, uint256 remaining) = gameTemplate.curveState();
        assertEq(remaining, CURVE_SUPPLY - sold);
        (uint256 out, uint256 used) = gameTemplate.quote(ethIn);
        assertLe(out, remaining, "never sells past the curve");
        assertLe(used, ethIn);
        assertGe((vEth + used) * (vTok - out), K, "product never below K");
        if (out < remaining) assertEq(used, ethIn);
        if (remaining == 0 || ethIn == 0) assertEq(out + used, 0);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_quoteIsMonotoneInEth(uint256 sold, uint256 a, uint256 b) public {
        sold = bound(sold, 0, CURVE_SUPPLY);
        a = bound(a, 0, 5 ether);
        b = bound(b, a, 5 ether);
        _setCurve(gameTemplate, sold);
        (uint256 outA, uint256 usedA) = gameTemplate.quote(a);
        (uint256 outB, uint256 usedB) = gameTemplate.quote(b);
        assertLe(outA, outB, "more ETH never buys fewer tokens");
        assertLe(usedA, usedB);
    }

    // ---- roll split -------------------------------------------------------------------------
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_rollSplitConservesEveryWei(uint8 nRolls, bool viaGenesis) public {
        uint256 n = bound(nRolls, 1, 12);
        openPad();
        PadGame g = pvp;
        if (!viaGenesis) {
            graduatePvp();
            g = PadGame(pad.gameOf(pad.launch("F", "F", "")));
        }
        mintAll(g, n);
        advance(10 minutes);
        uint256 potBefore = g.pot();
        uint256 burnBefore = liq.burnBucket() + liq.totalBurnedEth();
        for (uint256 i; i < n; ++i) {
            rollAs(g, players[i]);
        }
        uint256 paidIn = n * 0.002 ether;
        if (viaGenesis) {
            assertEq(g.ethRaised() + g.pot() - potBefore, paidIn, "genesis: curve + pot take everything");
            assertEq(liq.burnBucket() + liq.totalBurnedEth(), burnBefore);
        } else {
            uint256 burn = liq.burnBucket() + liq.totalBurnedEth() - burnBefore;
            assertEq(burn, paidIn * 2 / 100, "2% to the burn bucket");
            assertEq(g.ethRaised() + g.pot() - potBefore + burn, paidIn);
        }
        assertEq(g.ethRaised(), paidIn * 90 / 100, "90% to the curve while it has supply");
        assertEq(address(g).balance, g.pot() + g.ethRaised(), "balance backs the accounting");
    }

    // ---- king split -------------------------------------------------------------------------
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_firstBidSplitsToTheWei(uint256 bid) public {
        bid = bound(bid, 0.01 ether, 50 ether);
        graduatePvp();
        vm.deal(players[5], bid);
        uint256 carry = pad.carryPot();
        uint256 burn = liq.burnBucket() + liq.totalBurnedEth();
        uint256 dev = OWNER.balance + king.claimable(OWNER);
        vm.prank(players[5]);
        king.takeCrown{value: bid}();
        uint256 dCarry = pad.carryPot() - carry;
        uint256 dBurn = liq.burnBucket() + liq.totalBurnedEth() - burn;
        uint256 dDev = OWNER.balance + king.claimable(OWNER) - dev;
        assertEq(dCarry, bid / 2, "50% to games (none live: carry)");
        assertEq(dBurn, bid / 4, "25% burn");
        assertEq(dDev, bid - bid / 2 - bid / 4, "25% dev takes the rounding");
        assertEq(dCarry + dBurn + dDev, bid);
        assertEq(address(king).balance, king.claimable(OWNER), "king holds only claimables");
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_challengeRefundsOldKingAndSplitsOnlyTheExtra(uint256 first, uint256 second) public {
        first = bound(first, 0.01 ether, 20 ether);
        second = bound(second, first * 11_000 / 10_000, 60 ether);
        graduatePvp();
        vm.deal(players[5], first);
        vm.deal(players[6], second);
        vm.prank(players[5]);
        king.takeCrown{value: first}();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 carry = pad.carryPot();
        uint256 burn = liq.burnBucket() + liq.totalBurnedEth();
        uint256 dev = OWNER.balance + king.claimable(OWNER);
        uint256 oldKingBefore = players[5].balance; // may already hold LP fees distributed while king
        vm.prank(players[6]);
        king.takeCrown{value: second}();
        assertEq(players[5].balance - oldKingBefore, first, "old king refunded in full");
        uint256 extra = second - first;
        assertEq(pad.carryPot() - carry, extra / 2);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - burn, extra / 4);
        assertEq(OWNER.balance + king.claimable(OWNER) - dev, extra - extra / 2 - extra / 4);
        assertEq(king.nextMinBid(), second * 11_000 / 10_000);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_challengeBelow110PercentOrWithinHoldReverts(uint256 first, uint256 low, uint256 wait) public {
        first = bound(first, 0.01 ether, 20 ether);
        low = bound(low, 0, first * 11_000 / 10_000 - 1);
        wait = bound(wait, 0, 1 hours - 1);
        graduatePvp();
        vm.deal(players[5], first);
        vm.deal(players[6], 100 ether);
        vm.prank(players[5]);
        king.takeCrown{value: first}();
        vm.warp(vm.getBlockTimestamp() + wait);
        vm.prank(players[6]);
        vm.expectRevert(bytes("king holds"));
        king.takeCrown{value: 100 ether}();
        vm.warp(king.challengeOpensAt());
        vm.prank(players[6]);
        vm.expectRevert(bytes("bid too low"));
        king.takeCrown{value: low}();
        assertEq(king.king(), players[5]);
    }

    // ---- payout -----------------------------------------------------------------------------
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_finalizePaysTopHalfWithTriangularWeightsAndNothingLeaks(uint8 nRaw, uint256 extraPot) public {
        uint256 n = bound(nRaw, 1, 11);
        extraPot = bound(extraPot, 0, 3 ether);
        openPad();
        mintAll(pvp, n);
        advance(10 minutes);
        for (uint256 k; k < 5; ++k) {
            for (uint256 i; i < n; ++i) {
                rollAs(pvp, players[i]); // every imp keeps rolling so all are alive at the hard end
            }
            advance(9 minutes);
        }
        for (uint256 i; i < n; ++i) {
            rollAs(pvp, players[i]);
        }
        arb.advance(4);
        pvp.resolvePending(16);
        // funded ETH (carry pot / king share) only ever arrives from the pad
        vm.deal(address(pad), extraPot);
        if (extraPot != 0) {
            vm.prank(address(pad));
            pvp.fundPot{value: extraPot}();
        }
        // distinct heights: imp i sits at height n - i, so imp 0 ranks first
        for (uint256 i; i < n; ++i) {
            _setHeightAt(pvp, i, int16(int256(n - i)), 1);
        }
        advance(5 minutes);
        assertTrue(pvp.ended());
        uint256 p = pvp.pot();
        uint256 funded = pvp.fundedPot();
        uint256 earned = pvp.rollPot();
        assertEq(funded, extraPot);
        assertEq(earned + funded, p);
        assertEq(earned, n * 6 * 0.0002 ether, "genesis: 10% of every roll is roll income");
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = players[i].balance;
        }
        uint256 carryBefore = pad.carryPot();
        uint256 finalizerBefore = players[11].balance;
        vm.prank(players[11]);
        pvp.finalize();
        // finalizer: 0.5% of the whole pot, max 0.005 ETH, never more than the roll income
        uint256 fee = p * 50 / 10_000;
        if (fee > 0.005 ether) fee = 0.005 ether;
        if (fee > earned) fee = earned;
        // funded ETH: all returned with fewer than five living, otherwise the part above 3x roll income
        uint256 returned;
        if (n < 5) returned = funded;
        else if (funded > earned * 3) returned = funded - earned * 3;
        uint256 ranks = p - fee - returned;
        uint256 paid = (n + 1) / 2;
        uint256 weightSum = paid * (paid + 1) / 2;
        uint256 sent;
        for (uint256 r; r < n; ++r) {
            uint256 expect = r < paid ? ranks * (paid - r) / weightSum : 0;
            assertEq(players[r].balance - before[r], expect, "rank payout");
            sent += expect;
        }
        assertEq(players[11].balance - finalizerBefore, fee);
        assertEq(pad.carryPot() - carryBefore, returned + (ranks - sent), "returned funded ETH and dust to carry");
        assertEq(pvp.pot(), 0);
        assertEq(pvp.fundedPot(), 0);
        assertEq(address(pvp).balance, pvp.ethRaised());
        assertLe(sent + fee, earned + (n < 5 ? 0 : earned * 3), "players and finalizer never get above 4x roll income");
    }

    /// @notice The funded-pot gate: with every Imp alive, the amount released never exceeds 3x the
    /// roll income, and nothing of it is released below five living Imps.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_fundedReleaseNeverExceedsThreeTimesRollIncome(uint8 nRaw, uint256 funded, uint8 rollsRaw) public {
        uint256 n = bound(nRaw, 1, 8);
        uint256 rounds = bound(rollsRaw, 1, 3);
        funded = bound(funded, 1, 5 ether);
        openPad();
        mintAll(pvp, n);
        advance(10 minutes);
        for (uint256 k; k < rounds; ++k) {
            for (uint256 i; i < n; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        vm.deal(address(pad), funded);
        vm.prank(address(pad));
        pvp.fundPot{value: funded}();
        // bell now: every Imp rolled within the last 10 minutes, so all n are alive at the end
        _setBell(pvp, uint64(vm.getBlockTimestamp()), players[0]);
        arb.advance(4);
        pvp.resolvePending(64);
        uint256 earned = pvp.rollPot();
        uint256 carryBefore = pad.carryPot();
        uint256 playersBefore;
        for (uint256 i; i < n; ++i) {
            playersBefore += players[i].balance;
        }
        vm.prank(players[11]);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), n);
        uint256 playersAfter;
        for (uint256 i; i < n; ++i) {
            playersAfter += players[i].balance;
        }
        uint256 released = n < 5 ? 0 : (funded > earned * 3 ? earned * 3 : funded);
        uint256 returned = funded - released;
        uint256 toPlayers = playersAfter - playersBefore;
        uint256 toCarry = pad.carryPot() - carryBefore;
        assertGe(toCarry, returned, "unreleased funded ETH returns to the carry");
        assertLe(toPlayers, earned + released, "players never get more than roll income plus the release");
        assertEq(toPlayers + toCarry + (players[11].balance - 10 ether), earned + funded, "nothing leaks");
    }

    function _setBell(PadGame g, uint64 at, address ringer) internal {
        uint256 word = uint256(g.firstMintAt()) | (uint256(at) << 64) | (uint256(g.maxActivity()) << 128);
        vm.store(address(g), bytes32(uint256(8)), bytes32(word));
        vm.store(address(g), bytes32(uint256(9)), bytes32(uint256(uint160(ringer))));
        assertEq(g.bellAt(), at, "bell set");
    }

    // ---- helpers ----------------------------------------------------------------------------
    function _setCurve(PadGame g, uint256 sold) internal {
        uint256 vEth = (K + (VTOK - sold) - 1) / (VTOK - sold);
        vm.store(address(g), bytes32(uint256(5)), bytes32(vEth - 1 ether));
        vm.store(address(g), bytes32(uint256(6)), bytes32(sold));
    }

    function _setHeightAt(PadGame g, uint256 i, int16 h, uint40 at) internal {
        PadGame.Imp memory imp = g.getImp(i);
        uint256 word = uint256(uint160(imp.owner)) | (uint256(uint16(h)) << 160) | (uint256(imp.lastRoll) << 176)
            | (uint256(at) << 216);
        vm.store(address(g), bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2), bytes32(word));
        assertEq(g.getImp(i).height, h, "height set");
    }
}
