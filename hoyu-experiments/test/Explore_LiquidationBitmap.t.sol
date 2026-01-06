// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
    Explore_LiquidationBitmap (Hoyu)

    Purpose:
      - Pre-condition AMM price into a region where borrowing becomes possible
      - Create many near-critical loans (dense bitmap)
      - Sweep trade sizes and measure:
          * liquidations = popcount(bitmapBefore XOR bitmapAfter)
          * slippage (bps) relative to mid price
      - Emit rich CSV for verification / outlier review
      - Never fail due to swap/borrow reverts inside the sweep (reverts become data)

    Output:
      data/trade_liquidation_curve.csv

    Notes:
      - If you hit "stack too deep", enable viaIR in foundry.toml:
          via_ir = true
        and optimizer = true.
*/

import {Test} from "forge-std/Test.sol";
import {HoyuFactory} from "../src/HoyuFactory.sol";
import {HoyuVaultDeployer} from "../src/HoyuVaultDeployer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ---------------- Interfaces ----------------

interface IHoyuPair {
    function mint(address to) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32);
    function vault() external view returns (address);
}

interface IHoyuVault {
    function depositCollateral(uint256 amount, address to) external;
    function takeOutLoan(uint256 amount, address to, bytes calldata data) external;
    function loanBitmap() external view returns (uint256);
}

/// ---------------- Mintable ERC20 ----------------

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// ---------------- Test ----------------

contract Explore_LiquidationBitmap is Test {
    // --- AMM initial state (intentionally skewed) ---
    uint256 internal constant INIT_CURRENCY_LIQ = 200_000e18;
    uint256 internal constant INIT_ALTCOIN_LIQ  = 1_000_000e18;

    // --- collateral / loan seeding ---
    uint256 internal constant SEED_COLLATERAL = 800_000e18;
    uint256 internal constant SEED_MAX_LOANS  = 512;

    // --- preconditioning trade (moves price BEFORE borrowing) ---
    uint256 internal constant PRE_TRADE_IN = 80_000e18;
    uint256 internal constant PRE_TRADE_OUT_BPS = 9000; // execute 90% of maxAltOut

    string internal constant CSV_PATH = "data/trade_liquidation_curve.csv";

    MockERC20 internal currency;
    MockERC20 internal altcoin;

    HoyuFactory internal factory;
    HoyuVaultDeployer internal vaultDeployer;

    IHoyuPair internal pair;
    IHoyuVault internal vault;

    address internal trader        = address(0xBEEF);
    address internal earlyBorrower = address(0xA11CE);

    uint256[] internal tradeSizes;

    // ---------------- setup ----------------

    function setUp() external {
        vm.createDir("data", true);

        currency = new MockERC20("Currency", "CUR");
        altcoin  = new MockERC20("Altcoin",  "ALT");

        vaultDeployer = new HoyuVaultDeployer();
        factory = new HoyuFactory(address(vaultDeployer));
        vaultDeployer.setFactory(address(factory));

        factory.createPair(address(currency), address(altcoin));
        address pairAddr = factory.getPair(address(currency), address(altcoin));

        pair  = IHoyuPair(pairAddr);
        vault = IHoyuVault(pair.vault());

        // --- seed AMM ---
        currency.mint(address(this), INIT_CURRENCY_LIQ);
        altcoin.mint(address(this), INIT_ALTCOIN_LIQ);
        currency.transfer(pairAddr, INIT_CURRENCY_LIQ);
        altcoin.transfer(pairAddr, INIT_ALTCOIN_LIQ);
        pair.mint(address(this));

        // --- Phase A: pre-condition price into borrowable region ---
        _preconditionPriceIntoBorrowableRegion();

        // --- seed collateral (borrower) ---
        altcoin.mint(earlyBorrower, SEED_COLLATERAL);
        vm.prank(earlyBorrower);
        altcoin.approve(address(vault), type(uint256).max);
        vm.prank(earlyBorrower);
        vault.depositCollateral(SEED_COLLATERAL, earlyBorrower);

        // --- find max borrowable loan (now that price is in-range) ---
        uint256 maxLoan = _findMaxLoan(earlyBorrower, 1e18, 200_000e18);
        require(maxLoan > 0, "BORROW IMPOSSIBLE");

        // --- seed many near-critical loans (dense bitmap) ---
        uint256 loanSize = (maxLoan * 9) / 10;
        uint256 created = _seedManyLoans(earlyBorrower, loanSize, SEED_MAX_LOANS);
        require(created > 0, "NO LOANS CREATED");

        // --- trade sweep (log-spaced) ---
        uint256 base = 1_000e18;
        for (uint256 i = 0; i < 30; i++) {
            tradeSizes.push(base);
            base = (base * 12) / 10; // ~1.2x
        }

        // --- CSV header ---
        vm.writeFile(
            CSV_PATH,
            "tradeSize,maxAltOut,liquidations,popcountBefore,popcountAfter,"
            "bitmapBefore,bitmapAfter,bitmapXor,"
            "r0Before,r1Before,r0After,r1After,"
            "midPriceWad,execPriceWad,slippageBps\n"
        );
    }

    // ---------------- experiment ----------------

    function test_tradeSize_vs_liquidations() external {
        for (uint256 i = 0; i < tradeSizes.length; i++) {
            uint256 tradeSize = tradeSizes[i];
            uint256 snap = vm.snapshot();

            uint256 bitmapBefore = _safeBitmap();
            uint256 popBefore = _popcount(bitmapBefore);

            (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
            uint256 midPriceWad =
                r1Before == 0 ? 0 : (uint256(r0Before) * 1e18) / uint256(r1Before);

            uint256 maxAltOut = _maxAltcoinOutForCurrencyIn(tradeSize);

            if (maxAltOut == 0) {
                _writeRow(
                    tradeSize, 0, 0,
                    popBefore, popBefore,
                    bitmapBefore, bitmapBefore, 0,
                    r0Before, r1Before, r0Before, r1Before,
                    midPriceWad, 0, 0
                );
                vm.revertTo(snap);
                continue;
            }

            bool executed;
            try this._executeCurrencyInAltcoinOut(tradeSize, maxAltOut) {
                executed = true;
            } catch {
                executed = false;
            }

            if (!executed) {
                _writeRow(
                    tradeSize, maxAltOut, 0,
                    popBefore, popBefore,
                    bitmapBefore, bitmapBefore, 0,
                    r0Before, r1Before, r0Before, r1Before,
                    midPriceWad, 0, 0
                );
                vm.revertTo(snap);
                continue;
            }

            uint256 bitmapAfter = _safeBitmap();
            uint256 popAfter = _popcount(bitmapAfter);
            uint256 bitmapXor = bitmapBefore ^ bitmapAfter;
            uint256 liquidations = _popcount(bitmapXor);

            (uint112 r0After, uint112 r1After,) = pair.getReserves();
            uint256 execPriceWad = (tradeSize * 1e18) / maxAltOut;
            uint256 slippageBps = _slippageBps(midPriceWad, execPriceWad);

            _writeRow(
                tradeSize, maxAltOut, liquidations,
                popBefore, popAfter,
                bitmapBefore, bitmapAfter, bitmapXor,
                r0Before, r1Before, r0After, r1After,
                midPriceWad, execPriceWad, slippageBps
            );

            vm.revertTo(snap);
        }
    }

    // ---------------- Phase A: preconditioning ----------------

    function _preconditionPriceIntoBorrowableRegion() internal {
        // Find a feasible ALT out for a given CUR in, then execute a conservative fraction.
        // This avoids hardcoding an out amount that may revert on different parameters.
        uint256 maxAltOut = _maxAltcoinOutForCurrencyIn(PRE_TRADE_IN);
        if (maxAltOut == 0) return;

        uint256 altOut = (maxAltOut * PRE_TRADE_OUT_BPS) / 10_000;
        if (altOut == 0) return;

        // Execute the swap (not in a snapshot; we want the price shift to persist)
        currency.mint(trader, PRE_TRADE_IN);
        vm.prank(trader);
        currency.transfer(address(pair), PRE_TRADE_IN);

        vm.prank(trader);
        // Buy ALT (amount1Out), paying CUR in
        try pair.swap(0, altOut, trader, "") {
            // ok
        } catch {
            // If this fails, we keep going; borrowing may still be impossible,
            // but then the explicit "BORROW IMPOSSIBLE" require will tell us.
        }
    }

    // ---------------- mechanics ----------------

    function _executeCurrencyInAltcoinOut(uint256 amountIn, uint256 altOut) external {
        currency.mint(trader, amountIn);
        vm.prank(trader);
        currency.transfer(address(pair), amountIn);
        vm.prank(trader);
        pair.swap(0, altOut, trader, "");
    }

    function _maxAltcoinOutForCurrencyIn(uint256 amountIn) internal returns (uint256) {
        (, uint112 r1,) = pair.getReserves();
        if (r1 <= 1) return 0;

        uint256 lo = 0;
        uint256 hi = uint256(r1) - 1;
        uint256 best = 0;

        for (uint256 i = 0; i < 32 && lo <= hi; i++) {
            uint256 mid = (lo + hi) / 2;
            if (_trySwapCurrencyForAltcoin(amountIn, mid)) {
                best = mid;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        return best;
    }

    function _trySwapCurrencyForAltcoin(uint256 amountIn, uint256 altOut) internal returns (bool ok) {
        uint256 snap = vm.snapshot();

        currency.mint(trader, amountIn);
        vm.prank(trader);
        currency.transfer(address(pair), amountIn);

        vm.prank(trader);
        try pair.swap(0, altOut, trader, "") {
            ok = true;
        } catch {
            ok = false;
        }

        vm.revertTo(snap);
    }

    // ---------------- loan calibration ----------------

    function _findMaxLoan(address borrower, uint256 low, uint256 high) internal returns (uint256 best) {
        for (uint256 i = 0; i < 32 && low <= high; i++) {
            uint256 mid = (low + high) / 2;
            uint256 snap = vm.snapshot();

            vm.prank(borrower);
            try vault.takeOutLoan(mid, borrower, "") {
                best = mid;
                low = mid + 1;
            } catch {
                high = mid - 1;
            }

            vm.revertTo(snap);
        }
    }

    function _seedManyLoans(address borrower, uint256 loanSize, uint256 maxCount) internal returns (uint256 created) {
        for (uint256 i = 0; i < maxCount; i++) {
            vm.prank(borrower);
            try vault.takeOutLoan(loanSize, borrower, "") {
                created++;
            } catch {
                break;
            }
        }
    }

    // ---------------- utilities ----------------

    function _safeBitmap() internal view returns (uint256) {
        try vault.loanBitmap() returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= (x - 1);
            c++;
        }
    }

    function _slippageBps(uint256 mid, uint256 exec) internal pure returns (uint256) {
        if (mid == 0) return 0;
        uint256 diff = exec > mid ? exec - mid : mid - exec;
        return (diff * 10_000) / mid;
    }

    function _writeRow(
        uint256 tradeSize,
        uint256 maxAltOut,
        uint256 liquidations,
        uint256 popBefore,
        uint256 popAfter,
        uint256 bitmapBefore,
        uint256 bitmapAfter,
        uint256 bitmapXor,
        uint256 r0Before,
        uint256 r1Before,
        uint256 r0After,
        uint256 r1After,
        uint256 midPriceWad,
        uint256 execPriceWad,
        uint256 slippageBps
    ) internal {
        vm.writeLine(
            CSV_PATH,
            string.concat(
                vm.toString(tradeSize), ",",
                vm.toString(maxAltOut), ",",
                vm.toString(liquidations), ",",
                vm.toString(popBefore), ",",
                vm.toString(popAfter), ",",
                vm.toString(bitmapBefore), ",",
                vm.toString(bitmapAfter), ",",
                vm.toString(bitmapXor), ",",
                vm.toString(r0Before), ",",
                vm.toString(r1Before), ",",
                vm.toString(r0After), ",",
                vm.toString(r1After), ",",
                vm.toString(midPriceWad), ",",
                vm.toString(execPriceWad), ",",
                vm.toString(slippageBps), "\n"
            )
        );
    }
}

