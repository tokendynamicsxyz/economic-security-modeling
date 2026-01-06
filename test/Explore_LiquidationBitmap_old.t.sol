// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
    Exploration test (Hoyu):

    Goal:
      - Seed a dense loan bitmap (many cheap loans early)
      - Apply large trades
      - Measure:
          * liquidation count = Hamming distance of loan bitmap
          * slippage of the triggering trade
      - Never fail due to reverts; treat them as data
      - Emit CSV for verification and outlier analysis

    Output:
      data/trade_liquidation_curve.csv
*/

import {Test} from "forge-std/Test.sol";

import {HoyuFactory} from "../src/HoyuFactory.sol";
import {HoyuVaultDeployer} from "../src/HoyuVaultDeployer.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ---------------- Minimal interfaces ----------------

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

/// ---------------- Experiment ----------------

contract Explore_LiquidationBitmap is Test {
    // liquidity
    uint256 internal constant INIT_CURRENCY_LIQ = 1_000_000e18;
    uint256 internal constant INIT_ALTCOIN_LIQ  = 1_000_000e18;

    // loan seeding
    uint256 internal constant SEED_COLLATERAL = 500_000e18;
    uint256 internal constant SEED_LOAN_SIZE  = 1_000e18;
    uint256 internal constant SEED_MAX_LOANS  = 512;

    string internal constant CSV_PATH = "data/trade_liquidation_curve.csv";

    // system
    MockERC20 internal currency;
    MockERC20 internal altcoin;

    HoyuFactory internal factory;
    HoyuVaultDeployer internal vaultDeployer;

    IHoyuPair internal pair;
    IHoyuVault internal vault;

    address internal trader = address(0xBEEF);
    address internal earlyBorrower = address(0xA11CE);

    // trade sweep (storage array, push-based)
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

        // seed AMM liquidity
        currency.mint(address(this), INIT_CURRENCY_LIQ);
        altcoin.mint(address(this), INIT_ALTCOIN_LIQ);

        currency.transfer(pairAddr, INIT_CURRENCY_LIQ);
        altcoin.transfer(pairAddr, INIT_ALTCOIN_LIQ);

        pair.mint(address(this));

        // seed dense loan bitmap
        _seedManyLoans(
            earlyBorrower,
            SEED_COLLATERAL,
            SEED_LOAN_SIZE,
            SEED_MAX_LOANS
        );

        // trade sweep sizes
        delete tradeSizes;
        tradeSizes.push(1_000e18);
        tradeSizes.push(2_000e18);
        tradeSizes.push(5_000e18);
        tradeSizes.push(10_000e18);
        tradeSizes.push(20_000e18);
        tradeSizes.push(50_000e18);
        tradeSizes.push(100_000e18);
        tradeSizes.push(200_000e18);
        tradeSizes.push(500_000e18);
        tradeSizes.push(1_000_000e18);

        // CSV header
        vm.writeFile(
            CSV_PATH,
            "tradeSize,maxAltOut,liquidations,midPriceWad,execPriceWad,slippageBps\n"
        );
    }

    // ---------------- experiment ----------------

    function test_tradeSize_vs_liquidations() external {
        for (uint256 i = 0; i < tradeSizes.length; i++) {
            uint256 tradeSize = tradeSizes[i];
            uint256 snap = vm.snapshot();

            uint256 bitmapBefore = _safeBitmap();
            (uint112 r0Before, uint112 r1Before,) = pair.getReserves();

            uint256 midPriceWad =
                r1Before == 0 ? 0 : (uint256(r0Before) * 1e18) / uint256(r1Before);

            // find feasible execution point
            uint256 maxAltOut = _maxAltcoinOutForCurrencyIn(tradeSize);

            if (maxAltOut == 0) {
                _writeRow(tradeSize, 0, 0, midPriceWad, 0, 0);
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
                _writeRow(tradeSize, maxAltOut, 0, midPriceWad, 0, 0);
                vm.revertTo(snap);
                continue;
            }

            uint256 bitmapAfter = _safeBitmap();
            uint256 liquidations = _popcount(bitmapBefore ^ bitmapAfter);

            uint256 execPriceWad =
                (tradeSize * 1e18) / maxAltOut;

            uint256 slippageBps =
                _slippageBps(midPriceWad, execPriceWad);

            _writeRow(
                tradeSize,
                maxAltOut,
                liquidations,
                midPriceWad,
                execPriceWad,
                slippageBps
            );

            vm.revertTo(snap);
        }
    }

    // ---------------- core mechanics ----------------

    function _executeCurrencyInAltcoinOut(uint256 amountIn, uint256 altOut) external {
        currency.mint(trader, amountIn);
        vm.prank(trader);
        currency.transfer(address(pair), amountIn);

        vm.prank(trader);
        pair.swap(0, altOut, trader, "");
    }

    function _maxAltcoinOutForCurrencyIn(uint256 amountIn) internal returns (uint256) {
        (uint112 r0 , uint112 r1,) = pair.getReserves();

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
        ok = false;

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

    // ---------------- loan seeding ----------------

    function _seedManyLoans(
        address borrower,
        uint256 collateralAmount,
        uint256 loanSize,
        uint256 maxCount
    ) internal {
        altcoin.mint(borrower, collateralAmount);
        vm.prank(borrower);
        altcoin.approve(address(vault), type(uint256).max);

        vm.prank(borrower);
        vault.depositCollateral(collateralAmount, borrower);

        for (uint256 i = 0; i < maxCount; i++) {
            vm.prank(borrower);
            try vault.takeOutLoan(loanSize, borrower, "") {
            } catch {
                break;
            }
        }
    }

    // ---------------- metrics ----------------

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
        uint256 diff = exec > mid ? (exec - mid) : (mid - exec);
        return (diff * 10_000) / mid;
    }

    function _writeRow(
        uint256 tradeSize,
        uint256 maxAltOut,
        uint256 liquidations,
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
                vm.toString(midPriceWad), ",",
                vm.toString(execPriceWad), ",",
                vm.toString(slippageBps), "\n"
            )
        );
    }
}

