// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {MockArbSys, MockPoolManager, Rejector} from "./mocks/Mocks.sol";

/// @notice Drives the whole pad with bounded random calls from a small set of actors (EOAs, the dev
/// and one receiver that rejects ETH). Every action is attempted; reverts are expected for bad
/// states and are swallowed. Ghost state records what must never move backwards.
contract PadHandler is Test {
    PvPPad public pad;
    PadLiquidity public liq;
    KingOfThePad public king;
    MockArbSys public arb;
    MockPoolManager public pm;
    address public dev;

    address[] public actors;
    uint256 public externalEth; // ETH created by vm.deal to simulate pool trading fees
    uint256 public kingBidChanges;
    uint256 public successfulRolls;
    uint256 public successfulCrowns;
    uint256 public successfulLaunches;
    uint256 public successfulFinalizes;
    uint256 public successfulGraduations;
    uint256 public successfulRestarts;

    mapping(address => bool) public ghostEnded;
    mapping(address => bool) public ghostFinalized;
    mapping(address => bool) public ghostGraduated;
    mapping(address => bool) public ghostFailed;
    mapping(address => uint256) public ghostEndTime;
    bool public ghostOpened;

    constructor(
        PvPPad pad_,
        PadLiquidity liq_,
        KingOfThePad king_,
        MockArbSys arb_,
        MockPoolManager pm_,
        address dev_
    ) {
        pad = pad_;
        liq = liq_;
        king = king_;
        arb = arb_;
        pm = pm_;
        dev = dev_;
    }

    function addActor(address a) external {
        actors.push(a);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---- actions ---------------------------------------------------------------------------------
    function mint(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        vm.prank(_actor(a));
        try game.mint() {} catch {}
        _after();
    }

    function roll(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        address who = _actor(a);
        if (who.balance < 0.002 ether) return;
        vm.prank(who);
        try game.roll{value: 0.002 ether}() {
            successfulRolls += 1;
        } catch {}
        _after();
    }

    function warp(uint256 secs, uint256 blocks) external {
        secs = bound(secs, 1, 12 minutes);
        blocks = bound(blocks, 0, 300);
        vm.warp(vm.getBlockTimestamp() + secs);
        arb.advance(blocks);
        _after();
    }

    function poke(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        vm.prank(_actor(a));
        try game.poke() {} catch {}
        _after();
    }

    function finalize(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        vm.prank(_actor(a));
        try game.finalize() {
            successfulFinalizes += 1;
        } catch {}
        _after();
    }

    function graduate(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        vm.prank(_actor(a));
        try game.graduate() {
            successfulGraduations += 1;
        } catch {}
        _after();
    }

    function resolve(uint256 g, uint256 max) external {
        max = bound(max, 0, 20);
        _game(g).resolvePending(max);
        _after();
    }

    function padUpkeep(uint256 a) external {
        vm.prank(_actor(a));
        pad.upkeep();
        _after();
    }

    function claimGame(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        vm.prank(_actor(a));
        try game.claim() {} catch {}
        _after();
    }

    function claimLiquidity(uint256 a) external {
        vm.prank(_actor(a));
        try liq.claim() {} catch {}
        _after();
    }

    function claimKing(uint256 a) external {
        vm.prank(_actor(a));
        try king.claim() {} catch {}
        _after();
    }

    /// @dev Nobody but the pad may top up a pot: a donation from any actor (players, dev, the king
    /// contract's address is not an actor) must be refused whatever the game's state.
    function fundPot(uint256 a, uint256 g, uint256 amount) external {
        amount = bound(amount, 0, 0.5 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        PadGame game = _game(g);
        uint256 potBefore = game.pot();
        uint256 fundedBefore = game.fundedPot();
        vm.prank(who);
        try game.fundPot{value: amount}() {
            assertTrue(false, "stranger funded a pot");
        } catch Error(string memory reason) {
            assertEq(reason, "not pad");
        }
        assertEq(game.pot(), potBefore);
        assertEq(game.fundedPot(), fundedBefore);
        _after();
    }

    /// @dev Restarting the genesis succeeds exactly when the current genesis has failed.
    function restartGenesis(uint256 a) external {
        bool failedBefore = pad.genesisFailed();
        uint256 oldId = pad.genesisId();
        uint256 count = pad.launchCount();
        uint256 carry = pad.carryPot();
        vm.prank(_actor(a));
        try pad.restartGenesis() returns (uint256 id) {
            assertTrue(failedBefore, "restart without a failed genesis");
            successfulRestarts += 1;
            assertEq(id, count + 1);
            assertEq(pad.genesisId(), id);
            assertTrue(PadGame(pad.gameOf(id)).genesis());
            assertEq(PadGame(pad.gameOf(id)).fundedPot(), carry, "carry pot moves into the new genesis");
            assertEq(pad.carryPot(), 0);
        } catch {
            assertFalse(failedBefore, "failed genesis could not be restarted");
            assertEq(pad.genesisId(), oldId);
        }
        _after();
    }

    function fundCarry(uint256 a, uint256 amount) external {
        amount = bound(amount, 0, 0.5 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        vm.prank(who);
        pad.fundCarry{value: amount}();
        _after();
    }

    function fundBurn(uint256 a, uint256 amount) external {
        amount = bound(amount, 0, 0.5 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        vm.prank(who);
        liq.fundBurn{value: amount}();
        _after();
    }

    function takeCrown(uint256 a, uint256 amount) external {
        amount = bound(amount, 0.005 ether, 3 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        address prevKing = king.king();
        uint256 prevBid = king.bid();
        uint256 prevCrownedAt = king.crownedAt();
        bool genesisOk = pad.genesisGraduated();
        vm.prank(who);
        try king.takeCrown{value: amount}() {
            successfulCrowns += 1;
            assertTrue(genesisOk, "crown before genesis graduated");
            if (prevKing == address(0)) {
                assertGe(amount, 0.01 ether, "first bid below minimum");
            } else {
                assertGe(amount, prevBid * 11_000 / 10_000, "bid below 110%");
                assertGe(vm.getBlockTimestamp(), prevCrownedAt + 1 hours, "bid inside the hold");
            }
            assertEq(king.king(), who);
            assertEq(king.bid(), amount);
        } catch {}
        _after();
    }

    function launch(uint256 a, uint256 seed) external {
        address who = _actor(a);
        bool genesisOk = pad.genesisGraduated();
        bool genesisFailed = pad.genesisFailed();
        vm.prank(who);
        try pad.launch(seed % 2 == 0 ? "Alpha" : "Beta", "T", "") returns (uint256 id) {
            assertTrue(pad.opened(), "launch gate");
            assertEq(id, pad.launchCount());
            if (genesisFailed) {
                // a failed genesis turns launch() into a PvP relaunch; the requested launch is not made
                successfulRestarts += 1;
                assertEq(pad.genesisId(), id);
                assertTrue(PadGame(pad.gameOf(id)).genesis());
                assertEq(pad.getLaunch(id).creator, pad.owner());
            } else {
                successfulLaunches += 1;
                assertTrue(genesisOk, "launch without graduated genesis");
                assertFalse(PadGame(pad.gameOf(id)).genesis());
                assertEq(pad.getLaunch(id).creator, who);
            }
        } catch {
            assertFalse(genesisOk || genesisFailed, "launch refused although the gate was open");
        }
        _after();
    }

    function distribute(uint256 a, uint256 n) external {
        n = bound(n, 0, 4);
        vm.prank(_actor(a));
        try king.distribute(n) {} catch {}
        _after();
    }

    function burnChunk() external {
        liq.burnChunk();
        _after();
    }

    /// @dev Simulates trading fees on a graduated pool: ETH appears from outside (tracked), the token
    /// side is moved out of the dEaD balance so the supply bookkeeping stays exact.
    function creditFees(uint256 poolSeed, uint256 f0, uint256 f1) external {
        uint256 count = liq.poolCount();
        if (count == 0) return;
        f0 = bound(f0, 0, 0.05 ether);
        PadLiquidity.Pool memory p = liq.getPool(poolSeed % count);
        PadToken t = PadToken(p.token);
        uint256 deadBal = t.balanceOf(0x000000000000000000000000000000000000dEaD);
        f1 = bound(f1, 0, deadBal);
        vm.deal(address(pm), address(pm).balance + f0);
        externalEth += f0;
        if (f1 != 0) {
            vm.prank(0x000000000000000000000000000000000000dEaD);
            t.transfer(address(pm), f1);
        }
        pm.creditFees(liq.poolKey(p.token), f0, f1);
        _after();
    }

    function tokenTransfer(uint256 a, uint256 b, uint256 g, uint256 amount) external {
        uint256 id = g % pad.launchCount() + 1;
        PadToken t = PadToken(pad.tokenOf(id));
        address from = _actor(a);
        address to = _actor(b);
        uint256 bal = t.balanceOf(from);
        amount = bound(amount, 0, bal);
        bool unlocked = t.unlocked();
        vm.prank(from);
        try t.transfer(to, amount) {
            assertTrue(unlocked, "transfer succeeded while locked");
        } catch {
            assertFalse(unlocked, "unlocked transfer with balance failed");
        }
        _after();
    }

    // ---- ghost bookkeeping -----------------------------------------------------------------------
    function _after() internal {
        if (ghostOpened) assertTrue(pad.opened(), "pad closed again");
        else ghostOpened = pad.opened();
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame game = PadGame(pad.gameOf(i));
            address ga = address(game);
            bool ended = game.ended();
            if (ghostEnded[ga]) {
                assertTrue(ended, "ended game reopened");
                assertEq(game.endTime(), ghostEndTime[ga], "end time moved after the end");
            } else if (ended) {
                ghostEnded[ga] = true;
                ghostEndTime[ga] = game.endTime();
            }
            if (ghostFinalized[ga]) assertTrue(game.finalized(), "finalized flag cleared");
            else ghostFinalized[ga] = game.finalized();
            if (ghostGraduated[ga]) assertTrue(game.graduated(), "graduated flag cleared");
            else ghostGraduated[ga] = game.graduated();
            if (ghostFailed[ga]) assertTrue(game.failed(), "failed flag cleared");
            else ghostFailed[ga] = game.failed();
        }
    }

    function _game(uint256 seed) internal view returns (PadGame) {
        return PadGame(pad.gameOf(seed % pad.launchCount() + 1));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// forge-config: default.invariant.runs = 40
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantTest is BaseTest {
    PadHandler handler;
    Rejector rejector;
    uint256 initialEth;

    function setUp() public override {
        super.setUp();
        openPad();
        handler = new PadHandler(pad, liq, king, arb, pm, OWNER);
        rejector = new Rejector();
        for (uint256 i; i < 6; ++i) {
            vm.deal(players[i], 100 ether);
            handler.addActor(players[i]);
        }
        vm.deal(address(rejector), 100 ether);
        handler.addActor(address(rejector));
        vm.deal(OWNER, 100 ether);
        handler.addActor(OWNER);
        initialEth = _systemEth();

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](19);
        sels[0] = PadHandler.mint.selector;
        sels[1] = PadHandler.roll.selector;
        sels[2] = PadHandler.roll.selector;
        sels[3] = PadHandler.warp.selector;
        sels[4] = PadHandler.warp.selector;
        sels[5] = PadHandler.poke.selector;
        sels[6] = PadHandler.finalize.selector;
        sels[7] = PadHandler.graduate.selector;
        sels[8] = PadHandler.resolve.selector;
        sels[9] = PadHandler.padUpkeep.selector;
        sels[10] = PadHandler.claimGame.selector;
        sels[11] = PadHandler.claimLiquidity.selector;
        sels[12] = PadHandler.claimKing.selector;
        sels[13] = PadHandler.fundPot.selector;
        sels[14] = PadHandler.fundCarry.selector;
        sels[15] = PadHandler.takeCrown.selector;
        sels[16] = PadHandler.launch.selector;
        sels[17] = PadHandler.distribute.selector;
        sels[18] = PadHandler.creditFees.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        bytes4[] memory more = new bytes4[](4);
        more[0] = PadHandler.burnChunk.selector;
        more[1] = PadHandler.fundBurn.selector;
        more[2] = PadHandler.tokenTransfer.selector;
        more[3] = PadHandler.restartGenesis.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: more}));
    }

    // ---- value conservation ----------------------------------------------------------------------
    /// @notice Each game's balance is exactly what it owes: the pot, the curve ETH until graduation, and
    /// the failed pushes waiting to be claimed.
    function invariant_gameBalanceEqualsObligations() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            uint256 owed = g.pot() + (g.graduated() ? 0 : g.ethRaised());
            for (uint256 a; a < _payeeCount(); ++a) {
                owed += g.claimable(_payee(a));
            }
            assertEq(address(g).balance, owed, "game balance != pot + curve + claimables");
        }
    }

    function invariant_liquidityBalanceEqualsObligations() public view {
        uint256 owed = liq.burnBucket() + liq.kingEscrow();
        for (uint256 a; a < _payeeCount(); ++a) {
            owed += liq.claimable(_payee(a));
        }
        assertEq(address(liq).balance, owed, "liquidity balance != bucket + escrow + claimables");
    }

    function invariant_kingHoldsOnlyClaimables() public view {
        uint256 owed;
        for (uint256 a; a < _payeeCount(); ++a) {
            owed += king.claimable(_payee(a));
        }
        assertEq(address(king).balance, owed, "king balance != claimables");
    }

    function invariant_padHoldsOnlyCarryPot() public view {
        assertEq(address(pad).balance, pad.carryPot());
    }

    function invariant_systemEthConserved() public view {
        assertEq(_systemEth(), initialEth + handler.externalEth(), "ETH appeared or vanished");
    }

    // ---- token ----------------------------------------------------------------------------------
    function invariant_tokenSupplyFixedAndFullyAccounted() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadToken t = PadToken(pad.tokenOf(i));
            assertEq(t.totalSupply(), 1_000_000_000 ether, "supply changed");
            uint256 sum =
                t.balanceOf(pad.gameOf(i)) + t.balanceOf(address(liq)) + t.balanceOf(address(pm)) + t.balanceOf(DEAD);
            for (uint256 a; a < handler.actorCount(); ++a) {
                sum += t.balanceOf(handler.actors(a));
            }
            assertEq(sum, 1_000_000_000 ether, "tokens leaked to an unknown holder");
        }
    }

    function invariant_tokenUnlockedOnlyBySuccessfulGraduation() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadToken t = PadToken(pad.tokenOf(i));
            PadGame g = PadGame(pad.gameOf(i));
            assertEq(t.unlocked(), g.graduated() && !g.failed(), "unlock state out of step with graduation");
            if (g.failed()) assertEq(t.balanceOf(DEAD), 1_000_000_000 ether - g.tokensSold(), "failed: all burned");
            if (g.graduated()) assertEq(t.balanceOf(address(g)), 0, "graduated game still holds tokens");
        }
    }

    // ---- curve and game rules --------------------------------------------------------------------
    function invariant_curveNeverUnderchargesAndNeverOversells() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            assertLe(g.tokensSold(), 800_000_000 ether);
            assertLe(g.ethRaised(), 4 ether);
            (uint256 vEth, uint256 vTok,) = g.curveState();
            assertGe(vEth * vTok, 1 ether * 1_000_000_000 ether, "constant product below K");
            assertEq(g.tokensSold() == 0, g.ethRaised() == 0, "tokens without ETH or ETH without tokens");
        }
    }

    function invariant_impsAndRollsBounded() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            uint256 imps = g.impCount();
            assertLe(imps, 200);
            assertLe(g.pendingCount(), g.rollCount());
            assertLe(g.nextPending(), g.rollCount());
            for (uint256 j; j < imps; ++j) {
                PadGame.Imp memory imp = g.getImp(j);
                assertLe(imp.height, 50);
                assertGe(imp.height, -50);
                assertEq(g.impOf(imp.owner), j + 1, "owner index mismatch");
            }
            if (g.finalized()) {
                assertTrue(g.ended(), "finalized before the end");
                assertEq(g.pendingCount(), 0, "finalized with pending rolls");
                assertEq(g.pot(), 0, "pot left after finalize");
            }
            if (g.graduated()) assertTrue(g.finalized(), "graduated before finalize");
            if (g.failed()) assertTrue(g.graduated() && g.ethRaised() == 0, "failed with ETH raised");
            if (g.bellAt() != 0) assertTrue(g.ended(), "bell without end");
        }
    }

    function invariant_genesisGatesLaunchesAndKing() public view {
        uint256 gid = pad.genesisId();
        assertTrue(gid >= 1 && gid <= pad.launchCount(), "genesis id out of range");
        assertTrue(PadGame(pad.gameOf(gid)).genesis(), "current genesis is not a genesis game");
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            if (g.genesis()) {
                // every genesis but the current one is a failed one that was replaced
                if (i != gid) assertTrue(g.failed(), "replaced genesis that did not fail");
                assertEq(pad.getLaunch(i).creator, pad.owner(), "genesis belongs to the owner");
            } else {
                assertTrue(pad.genesisGraduated(), "launch without graduated genesis");
            }
        }
        if (pad.genesisGraduated()) assertFalse(pad.genesisFailed(), "graduated genesis reads as failed");
        if (king.king() != address(0)) {
            assertTrue(pad.genesisGraduated(), "king without graduated genesis");
            assertGe(king.bid(), 0.01 ether);
        }
        if (liq.totalBurnedEth() != 0) assertTrue(pad.genesisGraduated(), "burn before PvP pool");
        assertTrue(pad.opened());
    }

    /// @notice Funded ETH (carry pot, king share) is always a part of the pot, never roll income, and
    /// is gone once the game is finalized.
    function invariant_fundedPotIsPartOfPotAndClearedByFinalize() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            assertLe(g.fundedPot(), g.pot(), "funded above the pot");
            assertEq(g.rollPot(), g.pot() - g.fundedPot());
            (, uint256 weight) = g.isLiveForKing();
            assertEq(weight, g.rollPot(), "king weight is the roll income");
            if (g.finalized()) assertEq(g.fundedPot(), 0, "funded left after finalize");
            if (g.impCount() == 0 || g.rollCount() == 0) assertEq(g.rollPot(), 0, "roll income without a roll");
        }
    }

    function invariant_callSummary() public view {
        // informational: keeps the run honest about what the handler actually reached
        // the initial genesis plus every launch and relaunch the handler saw succeed is the whole registry
        assertEq(1 + handler.successfulLaunches() + handler.successfulRestarts(), pad.launchCount());
    }

    // ---- helpers ---------------------------------------------------------------------------------
    function _payeeCount() internal view returns (uint256) {
        return handler.actorCount() + 2;
    }

    function _payee(uint256 i) internal view returns (address) {
        uint256 c = handler.actorCount();
        if (i < c) return handler.actors(i);
        if (i == c) return address(king);
        return address(handler);
    }

    function _systemEth() internal view returns (uint256 total) {
        for (uint256 a; a < _payeeCount(); ++a) {
            total += _payee(a).balance;
        }
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            total += pad.gameOf(i).balance;
        }
        total += address(liq).balance + address(pad).balance + address(pm).balance + DEAD.balance;
    }
}
