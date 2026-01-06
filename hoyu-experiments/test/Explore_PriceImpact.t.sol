// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
    Exploration test:
    - Empirically map price impact of HoyuPair.swap
    - No assumptions about internal pricing math
    - No liquidation setup (baseline regime)
    - Outputs CSV for plotting

    Method:
    For each currencyIn size:
      - Binary search maximum feasible altcoinOut
      - Effective price = currencyIn / altcoinOut
*/

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {HoyuFactory} from "../src/HoyuFactory.sol";
import {HoyuPair} from "../src/HoyuPair.sol";
import {HoyuVaultDeployer} from "../src/HoyuVaultDeployer.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice minimal mintable ERC20 for experiments
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Explore_PriceImpact is Test {
    // ---------------- experiment parameters ----------------

    uint256 internal constant INIT_CURRENCY_LIQ = 1_000_000e18;
    uint256 internal constant INIT_ALTCOIN_LIQ  = 1_000_000e18;

    uint256 internal constant SWEEP_START_IN = 1e18;
    uint256 internal constant SWEEP_END_IN   = 50_000e18;
    uint256 internal constant SWEEP_STEP_IN  = 1_000e18;

    string internal constant CSV_PATH = "data/price_impact.csv";

    // ---------------- system under test ----------------

    MockERC20 internal currency;
    MockERC20 internal altcoin;

    HoyuFactory internal factory;
    HoyuVaultDeployer internal vaultDeployer;
    HoyuPair internal pair;

    address internal trader = address(0xBEEF);

    // ---------------- setup ----------------

    function setUp() external {
        // ensure output dir exists
        vm.createDir("data", true);

        currency = new MockERC20("Currency", "CUR");
        altcoin  = new MockERC20("Altcoin",  "ALT");

        vaultDeployer = new HoyuVaultDeployer();
        factory = new HoyuFactory(address(vaultDeployer));

        // critical wiring step
        vaultDeployer.setFactory(address(factory));

        factory.createPair(address(currency), address(altcoin));
        address pairAddr = factory.getPair(address(currency), address(altcoin));
        pair = HoyuPair(pairAddr);

        // seed AMM liquidity
        currency.mint(address(this), INIT_CURRENCY_LIQ);
        altcoin.mint(address(this), INIT_ALTCOIN_LIQ);

        currency.transfer(pairAddr, INIT_CURRENCY_LIQ);
        altcoin.transfer(pairAddr, INIT_ALTCOIN_LIQ);

        pair.mint(address(this));

        // CSV header
        vm.writeFile(
            CSV_PATH,
            "amountIn,amountOut,priceInPerOut,reserve0,reserve1\n"
        );
    }

    // ---------------- main exploration ----------------

    function test_sweep_currencyIn_altcoinOut() external {
        for (
            uint256 amountIn = SWEEP_START_IN;
            amountIn <= SWEEP_END_IN;
            amountIn += SWEEP_STEP_IN
        ) {
            uint256 maxOut = _maxAltcoinOutForCurrencyIn(amountIn);

            if (maxOut == 0) {
                _writeRow(amountIn, 0, 0);
                continue;
            }

            uint256 price = (amountIn * 1e18) / maxOut;
            _writeRow(amountIn, maxOut, price);
        }
    }

    // ---------------- core probe logic ----------------

    function _maxAltcoinOutForCurrencyIn(uint256 amountIn)
        internal
        returns (uint256)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();

        uint256 lo = 0;
        uint256 hi = uint256(r1) - 1;
        uint256 best = 0;

        // bounded binary search
        for (uint256 i = 0; i < 32; i++) {
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

    function _trySwapCurrencyForAltcoin(
        uint256 amountIn,
        uint256 altcoinOut
    ) internal returns (bool ok) {
        uint256 snap = vm.snapshot();

        // fund trader
        currency.mint(trader, amountIn);
        vm.prank(trader);
        currency.transfer(address(pair), amountIn);

        // swap(currency in, altcoin out)
        vm.prank(trader);
        try pair.swap(0, altcoinOut, trader, "") {
            ok = true;
        } catch {
            ok = false;
        }

        vm.revertTo(snap);
    }

    // ---------------- logging ----------------

    function _writeRow(
        uint256 amountIn,
        uint256 amountOut,
        uint256 price
    ) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();

        string memory line = string.concat(
            vm.toString(amountIn), ",",
            vm.toString(amountOut), ",",
            vm.toString(price), ",",
            vm.toString(uint256(r0)), ",",
            vm.toString(uint256(r1)), "\n"
        );

        vm.writeLine(CSV_PATH, line);

        // fast feedback
        console2.log("in/out/price", amountIn, amountOut, price);
    }
}

