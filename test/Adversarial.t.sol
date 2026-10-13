// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";

/// @notice Receiver that re-enters the contract paying it. Every re-entry must be refused by the guard,
/// which makes the push fail and the amount claimable instead.
contract Reenterer {
    address public target;
    bytes public data;
    uint256 public entered;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    receive() external payable {
        entered += 1;
        if (target != address(0)) {
            (bool ok,) = target.call(data);
            require(ok, "reentry refused");
        }
    }
}

/// @notice Failure paths and edges the happy-path suites do not reach: sold-out curve, finalize edge
/// cases, reentrancy, constructor and binding guards, king split edges, hash-window boundaries, events.
contract AdversarialTest is BaseTest {
    uint256 constant K = 1 ether * 1_000_000_000 ether;
    uint256 constant VTOK = 1_000_000_000 ether;
    uint256 constant CURVE_SUPPLY = 800_000_000 ether;

    event Opened(address indexed by, bytes32 salt, address hook);
    event Launched(
        uint256 indexed id, address indexed token, address indexed game, address creator, string name, string ticker
    );
    event Crowned(address indexed king, address indexed previous, uint256 bid, uint256 extra, uint256 refund);
    event Minted(address indexed owner, uint256 indexed imp, bool signupStarted);
    event Finalized(address indexed finalizer, uint256 pot, uint256 living, uint256 paid, bool bell);

    // ---- constructors and bindings ---------------------------------------------------------------
    function test_constructorsRejectZeroAddresses() public {
        vm.expectRevert(bytes("zero"));
        new PvPPad(address(0), address(tokenTemplate), address(gameTemplate));
        vm.expectRevert(bytes("zero"));
        new PvPPad(OWNER, address(0), address(gameTemplate));
        vm.expectRevert(bytes("zero"));
        new PvPPad(OWNER, address(tokenTemplate), address(0));
        vm.expectRevert(bytes("zero"));
        new PadLiquidity(address(0), address(pad));
        vm.expectRevert(bytes("zero"));
        new PadLiquidity(address(pm), address(0));
        vm.expectRevert(bytes("zero"));
        new KingOfThePad(address(pad), address(liq), address(0));
    }

    function test_openPadAndGenesisNeedBindings() public {
        PvPPad lone = new PvPPad(OWNER, address(tokenTemplate), address(gameTemplate));
        vm.prank(OWNER);
        vm.expectRevert(bytes("not bound"));
        lone.openPad(bytes32(0));
        vm.expectRevert(bytes("no liquidity"));
        lone.startGenesis();
        assertEq(lone.launchCount(), 0);
        assertFalse(lone.genesisGraduated(), "no launches: not graduated");
    }

    function test_kingConstructorCannotBindTwice() public {
        // a second KingOfThePad against the live pad is refused by both one-shot bindings
        vm.expectRevert(bytes("bound"));
        new KingOfThePad(address(pad), address(liq), OWNER);
    }

    function test_launchViewsRejectIdZero() public {
        vm.expectRevert();
        pad.getLaunch(0);
        vm.expectRevert();
        pad.gameOf(0);
        vm.expectRevert();
        pad.tokenOf(2);
    }

    // ---- open switch edges ------------------------------------------------------------------------
    function test_openPadRejectsExtraHookFlags() public {
        // bit 13 set plus another flag bit: the mask check must still refuse it
        bytes32 salt = _mineSaltFor(0x2001);
        vm.prank(OWNER);
        vm.expectRevert(bytes("hook flags"));
        pad.openPad(salt);
        assertFalse(pad.opened());
        assertEq(liq.hook(), address(0), "failed open leaves no hook");
    }

    function test_openPadEmitsAndIsFinal() public {
        bytes32 salt = mineSalt();
        address predicted = liq.hookAddressFor(salt);
        vm.expectEmit(true, false, false, true);
        emit Opened(OWNER, salt, predicted);
        vm.prank(OWNER);
        pad.openPad(salt);
        assertEq(pad.openSalt(), salt);
        // the deadline path is closed as well once opened
        vm.warp(pad.openDeadline() + 1);
        vm.prank(players[0]);
        vm.expectRevert(bytes("opened"));
        pad.openPad(salt);
    }

    function test_openPadAtExactDeadlineByStranger() public {
        bytes32 salt = mineSalt();
        vm.warp(pad.deployedAt() + 30 days);
        vm.prank(players[3]);
        pad.openPad(salt);
        assertTrue(pad.opened());
    }

    // ---- genesis gating ---------------------------------------------------------------------------
    function test_failedGenesisKeepsKingAndBurnClosedAndLaunchOnlyRelaunchesPvp() public {
        openPad();
        mintAll(pvp, 1);
        advance(20 minutes); // nobody rolled: all dead, nothing raised
        pvp.finalize();
        pvp.graduate();
        assertTrue(pvp.failed());
        assertTrue(pad.genesisFailed());
        assertFalse(pad.genesisGraduated());
        // launch() does not create "Foo": it relaunches PvP and hands back the new genesis id
        vm.prank(players[3]);
        uint256 id = pad.launch("Foo", "FOO", "ipfs://foo");
        assertEq(id, 2);
        assertEq(pad.genesisId(), 2);
        assertEq(pad.launchCount(), 2, "exactly one launch was created");
        PvPPad.Launch memory l = pad.getLaunch(2);
        assertEq(l.name, "Pepes Value Pepes");
        assertEq(l.ticker, "PVP");
        assertEq(l.imageURL, "");
        assertEq(l.creator, OWNER, "the relaunch belongs to the owner, not the caller");
        assertTrue(PadGame(l.game).genesis());
        assertFalse(pad.genesisFailed());
        assertFalse(pad.genesisGraduated());
        // the new genesis is waiting: ordinary launches and a second restart are refused
        vm.expectRevert(bytes("genesis not graduated"));
        pad.launch("Foo", "FOO", "");
        vm.expectRevert(bytes("genesis not failed"));
        pad.restartGenesis();
        // king and burn stay closed until a PvP graduates
        vm.prank(players[0]);
        vm.expectRevert(bytes("king not open"));
        king.takeCrown{value: 1 ether}();
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.5 ether}();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        liq.burnChunk();
        assertEq(liq.totalBurnedEth(), 0, "no PvP pool: nothing to buy");
        assertEq(liq.burnBucket(), 0.5 ether);
    }

    function test_restartGenesisNeedsOpenPadAndFailedGenesis() public {
        vm.expectRevert(bytes("pad not open"));
        pad.restartGenesis();
        openPad();
        vm.expectRevert(bytes("genesis not failed"));
        pad.restartGenesis();
        graduatePvp();
        vm.expectRevert(bytes("genesis not failed"));
        pad.restartGenesis();
        assertEq(pad.genesisId(), 1, "a graduated genesis is never replaced");
    }

    function test_failedGenesisRelaunchTakesTheCarryPotAsFundedEth() public {
        openPad();
        mintAll(pvp, 1);
        advance(20 minutes);
        pvp.finalize();
        pvp.graduate();
        vm.deal(address(this), 1 ether);
        pad.fundCarry{value: 0.3 ether}();
        uint256 id = pad.restartGenesis();
        PadGame g = PadGame(pad.gameOf(id));
        assertEq(pad.carryPot(), 0);
        assertEq(g.pot(), 0.3 ether);
        assertEq(g.fundedPot(), 0.3 ether, "carry is funded ETH, not roll income");
        assertEq(g.rollPot(), 0);
        (bool live, uint256 weight) = g.isLiveForKing();
        assertFalse(live);
        assertEq(weight, 0, "funded ETH never weighs in the king split");
    }

    function test_mintOnFreshLaunchBeforeItsOwnFirstMintIsStatusZero() public {
        graduatePvp();
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        assertEq(g.status(), 0);
        assertEq(g.endTime(), 0);
        assertFalse(g.ended());
        assertFalse(g.isAlive(0));
        (bool live,) = g.isLiveForKing();
        assertFalse(live);
        vm.expectRevert(bytes("not finalizable"));
        g.finalize();
        vm.expectRevert(bytes("not graduable"));
        g.graduate();
    }

    // ---- curve edges ------------------------------------------------------------------------------
    function test_soldOutCurveSendsWholeRollToPot() public {
        openPad();
        mintAll(pvp, 1);
        advance(10 minutes);
        _setCurve(pvp, CURVE_SUPPLY);
        (uint256 vEth, uint256 vTok, uint256 remaining) = pvp.curveState();
        assertEq(remaining, 0);
        assertEq(vEth, 5 ether);
        assertEq(vTok, 200_000_000 ether);
        (uint256 q, uint256 used) = pvp.quote(0.0018 ether);
        assertEq(q, 0);
        assertEq(used, 0);
        uint256 potBefore = pvp.pot();
        uint256 tokBefore = pvpToken.balanceOf(players[0]);
        rollAs(pvp, players[0]);
        assertEq(pvp.pot() - potBefore, 0.002 ether, "90% curve share + 8% + genesis 2% all to pot");
        assertEq(pvp.ethRaised(), 4 ether, "sold out stays sold out");
        assertEq(pvpToken.balanceOf(players[0]), tokBefore, "no tokens when sold out");
        assertEq(pvp.rollCount(), 1, "the dice still roll");
    }

    function test_lastRollOnCurveUsesOnlyRemainingEthAndRestToPot() public {
        openPad();
        mintAll(pvp, 1);
        advance(10 minutes);
        uint256 remaining = 1000 ether; // 1000 tokens left on the curve
        _setCurve(pvp, CURVE_SUPPLY - remaining);
        (uint256 vEth,,) = pvp.curveState();
        uint256 cost = 5 ether - vEth;
        assertLt(cost, 0.0018 ether, "remaining costs less than one roll's curve share");
        (uint256 q, uint256 used) = pvp.quote(0.0018 ether);
        assertEq(q, remaining);
        assertEq(used, cost);
        uint256 potBefore = pvp.pot();
        rollAs(pvp, players[0]);
        assertEq(pvp.ethRaised(), 4 ether, "curve closes at exactly 4 ETH");
        assertEq(pvp.tokensSold(), CURVE_SUPPLY);
        assertEq(pvp.pot() - potBefore, 0.002 ether - cost, "unused curve ETH goes to the pot");
        assertEq(pvpToken.balanceOf(players[0]), remaining);
    }

    function test_curveNeverUnderchargesAlongRealRolls() public {
        openPad();
        mintAll(pvp, 6);
        advance(10 minutes);
        for (uint256 r; r < 5; ++r) {
            for (uint256 i; i < 6; ++i) {
                rollAs(pvp, players[i]);
                (uint256 vEth, uint256 vTok,) = pvp.curveState();
                assertGe(vEth * vTok, K, "constant product never drops below K");
            }
            advance(61);
        }
        assertEq(pvp.ethRaised() + pvp.pot(), 30 * 0.002 ether);
    }

    // ---- RNG window boundaries --------------------------------------------------------------------
    function test_hashWindowBoundaryAt257And258Blocks() public {
        openPad();
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        uint256 c = pvp.getRoll(0).commitBlock;
        arb.set(c + 257); // commit+1 is exactly 256 blocks old: still readable
        pvp.resolvePending(1);
        PadGame.Roll memory r = pvp.getRoll(0);
        assertTrue(r.resolved && !r.expired, "resolves with hashes at the edge of the window");
        rollAs(pvp, players[1]);
        c = pvp.getRoll(1).commitBlock;
        arb.set(c + 258);
        pvp.resolvePending(1);
        r = pvp.getRoll(1);
        assertTrue(r.resolved && r.expired, "one block later the roll has expired");
    }

    function test_expiredRollAtZeroHeightStaysZeroAndNeverRingsBell() public {
        openPad();
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        arb.advance(400);
        pvp.resolvePending(1);
        assertEq(pvp.getImp(0).height, 0);
        assertEq(pvp.getImp(0).heightReachedAt, 0, "no movement, no timestamp");
        assertEq(pvp.bellAt(), 0);
        assertEq(pvp.pendingCount(), 0);
    }

    function test_resolveIsPermissionlessAndIdempotent() public {
        openPad();
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        arb.advance(4);
        vm.prank(address(0xDEAD1));
        pvp.resolvePending(100);
        assertEq(pvp.pendingCount(), 0);
        int256 h = pvp.getImp(0).height;
        pvp.resolvePending(100);
        pvp.poke();
        assertEq(pvp.getImp(0).height, h, "a resolved roll is never re-applied");
        assertEq(pvp.nextPending(), 1);
    }

    function test_bellOnlyRingsOnceAndNotForNegativeClampOverflow() public {
        openPad();
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        _setHeightAt(pvp, 0, -49, 0);
        _setHeightAt(pvp, 1, 49, 0);
        int256 d0 = _expectedDelta(address(pvp), 0, 0, pvp.getRoll(0).commitBlock);
        int256 d1 = _expectedDelta(address(pvp), 1, 0, pvp.getRoll(1).commitBlock);
        arb.advance(4);
        pvp.resolvePending(8);
        int256 h0 = pvp.getImp(0).height;
        int256 h1 = pvp.getImp(1).height;
        assertGe(h0, -50);
        assertLe(h1, 50);
        bool bell0 = d0 < 0;
        bool bell1 = d1 > 0;
        if (bell0) {
            assertEq(h0, -50, "negative cap also rings");
            assertEq(pvp.bellRinger(), players[0], "first resolved ringer keeps the bell");
        } else if (bell1) {
            assertEq(pvp.bellRinger(), players[1]);
        } else {
            assertEq(pvp.bellAt(), 0);
        }
        if (bell0 || bell1) assertTrue(pvp.ended());
    }

    // ---- finalize edges ---------------------------------------------------------------------------
    function test_noBellAllToRanksAndDustToCarry() public {
        openPad();
        mintAll(pvp, 3);
        advance(10 minutes);
        _keepAliveUntil55(pvp, 3); // everyone keeps rolling so all three are alive at the 60 minute hard end
        for (uint256 i; i < 3; ++i) {
            rollAs(pvp, players[i]);
        }
        arb.advance(4);
        pvp.resolvePending(8);
        _setHeightAt(pvp, 0, 10, 1);
        _setHeightAt(pvp, 1, 20, 1);
        _setHeightAt(pvp, 2, 5, 1);
        advance(5 minutes);
        assertTrue(pvp.ended() && !pvp.bellRang());
        assertEq(pvp.endTime(), pvp.hardEnd());
        uint256 p = pvp.pot();
        uint256 carryBefore = pad.carryPot();
        uint256[3] memory before = [players[0].balance, players[1].balance, players[2].balance];
        vm.expectEmit(true, false, false, true);
        emit Finalized(players[9], p - p * 50 / 10_000, 3, 2, false);
        vm.prank(players[9]);
        pvp.finalize();
        uint256 fee = p * 50 / 10_000;
        uint256 ranks = p - fee; // no bell: the whole remainder goes to the ranks
        assertEq(pvp.paidAtEnd(), 2, "ceil(3/2)");
        assertEq(players[1].balance - before[1], ranks * 2 / 3);
        assertEq(players[0].balance - before[0], ranks * 1 / 3);
        assertEq(players[2].balance, before[2], "rank 3 of 3 is unpaid");
        uint256 dust = ranks - ranks * 2 / 3 - ranks * 1 / 3;
        assertEq(pad.carryPot() - carryBefore, dust, "rounding dust carries forward");
        assertEq(address(pvp).balance, pvp.ethRaised(), "only curve ETH remains");
    }

    function test_bellRingerOutsideTopHalfStillGetsBellShare() public {
        openPad();
        mintAll(pvp, 3);
        advance(10 minutes);
        for (uint256 i; i < 3; ++i) {
            rollAs(pvp, players[i]);
        }
        arb.advance(4);
        pvp.resolvePending(8);
        _setHeightAt(pvp, 0, 30, 1);
        _setHeightAt(pvp, 1, 20, 1);
        _setHeightAt(pvp, 2, 5, 1);
        _setBell(pvp, uint64(vm.getBlockTimestamp()), players[2]);
        uint256 p = pvp.pot();
        uint256[3] memory before = [players[0].balance, players[1].balance, players[2].balance];
        vm.prank(players[9]);
        pvp.finalize();
        uint256 fee = p * 50 / 10_000;
        uint256 bell = (p - fee) * 20 / 100;
        uint256 ranks = p - fee - bell;
        assertEq(players[2].balance - before[2], bell, "ringer paid even when unranked");
        assertEq(players[0].balance - before[0], ranks * 2 / 3);
        assertEq(players[1].balance - before[1], ranks / 3);
    }

    function test_singleLivingImpTakesEverything() public {
        openPad();
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]); // player 0 rolls once at +10 and is dead by +20
        for (uint256 k; k < 5; ++k) {
            rollAs(pvp, players[1]);
            advance(9 minutes);
        }
        rollAs(pvp, players[1]); // player 1 rolls at +55 and is alive at the hard end
        advance(5 minutes);
        assertTrue(pvp.ended());
        assertEq(pvp.endTime(), pvp.hardEnd());
        assertTrue(pvp.isAlive(1) && !pvp.isAlive(0));
        uint256 p = pvp.pot();
        uint256 before = players[1].balance;
        vm.prank(players[9]);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 1);
        assertEq(pvp.paidAtEnd(), 1);
        assertEq(players[1].balance - before, p - p * 50 / 10_000);
    }

    function test_fundPotRefusedFromStrangersAndAfterFinalize() public {
        openPad();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("not pad"));
        pvp.fundPot{value: 1}();
        vm.prank(OWNER);
        vm.expectRevert(bytes("not pad"));
        pvp.fundPot{value: 0}();
        vm.prank(address(king));
        vm.expectRevert(bytes("not pad"));
        pvp.fundPot{value: 0}();
        mintAll(pvp, 1);
        advance(20 minutes);
        pvp.finalize();
        vm.deal(address(pad), 1 ether);
        vm.prank(address(pad));
        vm.expectRevert(bytes("finalized"));
        pvp.fundPot{value: 1}();
        assertEq(pvp.fundedPot(), 0);
    }

    function test_claimNothingReverts() public {
        vm.expectRevert(bytes("nothing"));
        pvp.claim();
        vm.expectRevert(bytes("nothing"));
        liq.claim();
        vm.expectRevert(bytes("nothing"));
        king.claim();
    }

    function test_finalizeWithTwoHundredLivingImpsWorstCaseOrderFitsInBlock() public {
        openPad();
        for (uint256 i; i < 200; ++i) {
            address who = address(uint160(0xC000 + i));
            vm.deal(who, 1 ether);
            vm.prank(who);
            pvp.mint();
        }
        advance(10 minutes);
        for (uint256 i; i < 200; ++i) {
            vm.prank(address(uint160(0xC000 + i)));
            pvp.roll{value: 0.002 ether}();
        }
        // the bell rings right away: all 200 rolled this second, so all 200 are alive at the end
        _setBell(pvp, uint64(vm.getBlockTimestamp()), address(0xC000));
        assertTrue(pvp.ended() && pvp.bellRang());
        arb.advance(4);
        while (pvp.pendingCount() != 0) {
            pvp.resolvePending(8);
        }
        // adversarial order: each imp outranks every earlier one, so the insertion sort shifts the most
        for (uint256 i; i < 200; ++i) {
            _setHeightAt(pvp, i, int16(int256(i / 4)), uint40(1_000_000 - i));
        }
        uint256 g = gasleft();
        vm.prank(players[9]);
        pvp.finalize();
        uint256 used = g - gasleft();
        emit log_named_uint("finalize gas, 200 living imps, worst-case order", used);
        assertEq(pvp.livingAtEnd(), 200);
        assertEq(pvp.paidAtEnd(), 100);
        assertLt(used, 32_000_000, "200-imp worst-case finalize fits an Arbitrum-stack block");
        assertEq(address(pvp).balance, pvp.ethRaised(), "every rank paid or claimable: none here");
    }

    // ---- reentrancy -------------------------------------------------------------------------------
    function test_reentrantWinnerIsRefusedAndMadeClaimable() public {
        openPad();
        Reenterer rj = new Reenterer();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        pvp.mint();
        mintAll(pvp, 1);
        advance(10 minutes);
        vm.prank(address(rj));
        pvp.roll{value: 0.002 ether}();
        rollAs(pvp, players[0]);
        arb.advance(4);
        pvp.resolvePending(8);
        _setHeightAt(pvp, 0, 20, 1);
        _setHeightAt(pvp, 1, 1, 1);
        _setBell(pvp, uint64(vm.getBlockTimestamp()), players[0]);
        rj.arm(address(pvp), abi.encodeCall(PadGame.claim, ()));
        uint256 p = pvp.pot();
        pvp.finalize();
        uint256 ranks = (p - p * 50 / 10_000) * 80 / 100;
        assertEq(pvp.claimable(address(rj)), ranks, "gas-capped push refused: amount claimable");
        // the claim itself re-enters claim(): the guard refuses it and the claim reverts, funds stay safe
        vm.prank(address(rj));
        vm.expectRevert(bytes("claim failed"));
        pvp.claim();
        assertEq(pvp.claimable(address(rj)), ranks);
        rj.arm(address(0), "");
        vm.prank(address(rj));
        pvp.claim();
        assertEq(pvp.claimable(address(rj)), 0);
        assertEq(address(rj).balance, 1 ether - 0.002 ether + ranks);
    }

    function test_reentrantKingRefundIsRefusedAndMadeClaimable() public {
        graduatePvp();
        Reenterer rj = new Reenterer();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        king.takeCrown{value: 0.01 ether}();
        rj.arm(address(king), abi.encodeCall(KingOfThePad.takeCrown, ()));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(players[1]);
        king.takeCrown{value: 0.02 ether}();
        assertEq(king.king(), players[1]);
        assertEq(king.claimable(address(rj)), 0.01 ether);
        assertEq(address(king).balance, 0.01 ether);
        rj.arm(address(0), "");
        vm.prank(address(rj));
        king.claim();
        assertEq(address(king).balance, 0);
    }

    function test_reentrantDistributeFromKingIsRefused() public {
        graduatePvp();
        Reenterer rj = new Reenterer();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        king.takeCrown{value: 0.01 ether}();
        rj.arm(address(liq), abi.encodeCall(PadLiquidity.distribute, (1)));
        vm.deal(address(pm), address(pm).balance + 0.1 ether);
        pm.creditFees(liq.poolKey(address(pvpToken)), 0.1 ether, 0);
        liq.distribute(1);
        assertApproxEqAbs(liq.claimable(address(rj)), 0.1 ether, 1e9, "push refused by the guard");
        assertEq(liq.kingEscrow(), 0);
        assertEq(address(liq).balance, liq.burnBucket() + liq.claimable(address(rj)));
    }

    // ---- king split edges -------------------------------------------------------------------------
    function test_fundGamesSplitsEquallyWhenAllPotsEmpty() public {
        graduatePvp();
        uint256 a = pad.launch("A", "A", "");
        uint256 b = pad.launch("B", "B", "");
        PadGame ga = PadGame(pad.gameOf(a));
        PadGame gb = PadGame(pad.gameOf(b));
        mintAll(ga, 5);
        mintAll(gb, 6);
        // launch A took the carry pot as funded ETH; neither game has roll income, so the weights are 0/0
        uint256 fundedA = ga.fundedPot();
        assertEq(ga.rollPot() + gb.rollPot(), 0);
        assertEq(gb.fundedPot(), 0);
        vm.prank(players[8]);
        king.takeCrown{value: 1 ether}();
        assertEq(ga.fundedPot() - fundedA, 0.25 ether);
        assertEq(gb.fundedPot(), 0.25 ether);
        assertEq(ga.pot(), fundedA + 0.25 ether);
        assertEq(gb.pot(), 0.25 ether);
        assertEq(ga.rollPot() + gb.rollPot(), 0, "the king share is funded ETH, never roll income");
    }

    function test_fundGamesOnlyLooksAtLastTenLaunches() public {
        graduatePvp();
        PadGame[] memory games = new PadGame[](11);
        for (uint256 i; i < 11; ++i) {
            games[i] = PadGame(pad.gameOf(pad.launch("G", "G", "")));
            mintAll(games[i], 5);
        }
        uint256 funded0 = games[0].fundedPot(); // the carry pot went to the first of them
        vm.prank(players[8]);
        king.takeCrown{value: 1 ether}();
        assertEq(games[0].fundedPot(), funded0, "launch #2 is outside the last ten");
        for (uint256 i = 1; i < 11; ++i) {
            assertEq(games[i].fundedPot(), 0.05 ether);
            assertEq(games[i].pot(), 0.05 ether);
        }
    }

    function test_fundGamesSkipsGamesWithFewerThanFiveImpsAndEndedOnes() public {
        graduatePvp();
        PadGame small = PadGame(pad.gameOf(pad.launch("S", "S", "")));
        PadGame done = PadGame(pad.gameOf(pad.launch("D", "D", "")));
        PadGame live = PadGame(pad.gameOf(pad.launch("L", "L", "")));
        mintAll(small, 4);
        mintAll(done, 5);
        advance(20 minutes); // `done` ends with every Imp dead; `small` ends too
        mintAll(live, 5);
        uint256 fundedSmall = small.fundedPot();
        uint256 fundedDone = done.fundedPot();
        vm.prank(players[8]);
        king.takeCrown{value: 1 ether}();
        assertEq(live.fundedPot(), 0.5 ether, "the only live game with five Imps takes the whole share");
        // upkeep inside takeCrown may finalize an ended game (funded returns to carry); it never adds
        assertLe(small.fundedPot(), fundedSmall);
        assertLe(done.fundedPot(), fundedDone);
    }

    function test_crownEventAndSameKingMayRebid() public {
        graduatePvp();
        vm.expectEmit(true, true, false, true);
        emit Crowned(players[0], address(0), 0.01 ether, 0.01 ether, 0);
        vm.prank(players[0]);
        king.takeCrown{value: 0.01 ether}();
        assertEq(king.crownCount(), 1);
        assertEq(king.challengeOpensAt(), vm.getBlockTimestamp() + 1 hours);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 before = players[0].balance;
        vm.prank(players[0]);
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.crownCount(), 2);
        assertEq(before - players[0].balance, 0.001 ether, "rebid costs only the extra after the refund");
        assertEq(king.bid(), 0.011 ether);
    }

    function test_takeCrownBeforeAnyBidRejectsZeroAndDust() public {
        graduatePvp();
        vm.prank(players[0]);
        vm.expectRevert(bytes("min bid"));
        king.takeCrown{value: 0}();
        vm.prank(players[0]);
        vm.expectRevert(bytes("min bid"));
        king.takeCrown{value: 0.01 ether - 1}();
    }

    function test_distributeRoundRobinAcrossPools() public {
        graduatePvp();
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        PadToken t = PadToken(pad.tokenOf(id));
        playOut(g, 6, 2);
        if (!g.graduated()) g.graduate();
        assertEq(liq.poolCount(), 2);
        vm.prank(players[0]);
        king.takeCrown{value: 0.01 ether}();
        vm.deal(address(pm), address(pm).balance + 0.3 ether);
        pm.creditFees(liq.poolKey(address(pvpToken)), 0.1 ether, 0);
        pm.creditFees(liq.poolKey(address(t)), 0.2 ether, 0);
        uint256 c = liq.distributeCursor();
        uint256 before = players[0].balance;
        king.distribute(1);
        uint256 first = players[0].balance - before;
        assertEq(liq.distributeCursor(), (c % 2) + 1);
        before = players[0].balance;
        king.distribute(1);
        uint256 second = players[0].balance - before;
        assertApproxEqAbs(first + second, 0.3 ether, 1e9, "both pools visited once");
        assertTrue(first != second, "different pools on consecutive calls");
        king.distribute(5);
        assertEq(liq.kingEscrow(), 0);
        assertEq(address(liq).balance, liq.burnBucket(), "every collected wei was forwarded to the king");
        assertGe(liq.getPool(0).ethFees + liq.getPool(1).ethFees, first + second);
    }

    // ---- token ------------------------------------------------------------------------------------
    function test_liquidityMayMoveLockedTokensAndApprovalsWorkAfterUnlock() public {
        openPad();
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        uint256 bal = pvpToken.balanceOf(players[0]);
        vm.prank(players[0]);
        pvpToken.approve(address(liq), bal);
        vm.prank(address(liq));
        pvpToken.transferFrom(players[0], players[1], bal);
        assertEq(pvpToken.balanceOf(players[1]), bal, "PadLiquidity is exempt from the lock");
        vm.prank(players[1]);
        vm.expectRevert(bytes("locked until graduation"));
        pvpToken.transfer(address(0), 1); // the lock is checked before the zero-address rule
        vm.prank(players[1]);
        vm.expectRevert(bytes("locked until graduation"));
        pvpToken.transfer(players[2], 1);
        vm.prank(players[1]);
        pvpToken.approve(players[2], bal);
        vm.prank(players[2]);
        vm.expectRevert(bytes("allowance"));
        pvpToken.transferFrom(players[1], players[2], bal + 1);
    }

    function test_mintEventsAndLaunchEvent() public {
        graduatePvp();
        uint256 next = pad.launchCount() + 1;
        vm.expectEmit(true, false, false, false);
        emit Launched(next, address(0), address(0), players[3], "Bar", "BAR");
        vm.prank(players[3]);
        pad.launch("Bar", "BAR", "ipfs://x");
        PvPPad.Launch memory l = pad.getLaunch(next);
        assertEq(l.imageURL, "ipfs://x");
        assertEq(l.createdAt, vm.getBlockTimestamp());
        assertTrue(pad.isGame(l.game));
        assertFalse(pad.isGame(l.token));
        assertEq(PadToken(l.token).totalSupply(), 1_000_000_000 ether);
        assertEq(PadToken(l.token).decimals(), 18);
        PadGame g = PadGame(l.game);
        vm.expectEmit(true, true, false, true);
        emit Minted(players[0], 0, true);
        vm.prank(players[0]);
        g.mint();
        vm.expectEmit(true, true, false, true);
        emit Minted(players[1], 1, false);
        vm.prank(players[1]);
        g.mint();
    }

    function test_hookRejectsForeignInitializeWithWrongKeyToo() public {
        openPad();
        PoolKey memory key = PoolKey(address(0), address(pvpToken), 3000, 60, pad.hook());
        vm.prank(players[0]);
        vm.expectRevert();
        pm.initialize(key, 1 << 96);
    }

    // ---- helpers ---------------------------------------------------------------------------------
    /// @dev From play start, players[0..n) roll every 9 minutes so none of them dies; ends at +55 min.
    function _keepAliveUntil55(PadGame g, uint256 n) internal {
        for (uint256 k; k < 5; ++k) {
            for (uint256 i; i < n; ++i) {
                rollAs(g, players[i]);
            }
            advance(9 minutes);
        }
    }

    function _mineSaltFor(uint160 want) internal view returns (bytes32) {
        bytes32 h = liq.hookInitCodeHash();
        for (uint256 i; i < 400_000; ++i) {
            uint160 a = uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(liq), bytes32(i), h))));
            if (a & 0x3FFF == want) return bytes32(i);
        }
        revert("no salt");
    }

    function _expectedDelta(address game, uint256 imp, uint256 nonce, uint256 commit) internal pure returns (int256) {
        bytes32 h1 = keccak256(abi.encode("arb", commit + 1));
        bytes32 h2 = keccak256(abi.encode("arb", commit + 2));
        bytes32 h3 = keccak256(abi.encode("arb", commit + 3));
        uint256 face = uint256(keccak256(abi.encode(game, imp, nonce, h1, h2, h3))) % 8;
        return face < 4 ? -int256(face + 1) : int256(face - 3);
    }

    /// @dev Put a game's curve at `sold` tokens sold with the ETH that the constant product implies.
    function _setCurve(PadGame g, uint256 sold) internal {
        uint256 vEth = (K + (VTOK - sold) - 1) / (VTOK - sold);
        vm.store(address(g), bytes32(uint256(5)), bytes32(vEth - 1 ether));
        vm.store(address(g), bytes32(uint256(6)), bytes32(sold));
        assertEq(g.tokensSold(), sold);
    }

    function _impSlot(uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
    }

    function _setHeightAt(PadGame g, uint256 i, int16 h, uint40 at) internal {
        PadGame.Imp memory imp = g.getImp(i);
        uint256 word = uint256(uint160(imp.owner)) | (uint256(uint16(h)) << 160) | (uint256(imp.lastRoll) << 176)
            | (uint256(at) << 216);
        vm.store(address(g), _impSlot(i), bytes32(word));
        assertEq(g.getImp(i).height, h, "height set");
    }

    function _setBell(PadGame g, uint64 at, address ringer) internal {
        uint256 word = uint256(g.firstMintAt()) | (uint256(at) << 64) | (uint256(g.maxActivity()) << 128);
        vm.store(address(g), bytes32(uint256(8)), bytes32(word));
        vm.store(address(g), bytes32(uint256(9)), bytes32(uint256(uint160(ringer))));
        assertEq(g.bellAt(), at, "bell set");
    }
}
