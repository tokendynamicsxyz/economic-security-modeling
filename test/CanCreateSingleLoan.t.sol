// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {HoyuFactory} from "../src/HoyuFactory.sol";
import {HoyuVaultDeployer} from "../src/HoyuVaultDeployer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ---------- Interfaces ----------

interface IHoyuPair {
    function mint(address to) external returns (uint256);
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function getReserves()
        external
        view
        returns (uint112 r0, uint112 r1, uint32);

    function vault() external view returns (address);
}

interface IHoyuVault {
    function depositCollateral(uint256 amount, address to) external;
    function takeOutLoan(uint256 amount, address to, bytes calldata data) external;
    function loanBitmap() external view returns (uint256);
}

/// ---------- Mintable ERC20 ----------

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// ---------- Test ----------

contract CanCreateSingleLoan is Test {
    MockERC20 internal currency;
    MockERC20 internal altcoin;

    HoyuFactory internal factory;
    HoyuVaultDeployer internal deployer;

    IHoyuPair internal pair;
    IHoyuVault internal vault;

    address internal borrower = address(0xA11CE);

    function setUp() external {
        // Deploy tokens
        currency = new MockERC20("Currency", "CUR");
        altcoin  = new MockERC20("Altcoin",  "ALT");

        // Deploy Hoyu
        deployer = new HoyuVaultDeployer();
        factory  = new HoyuFactory(address(deployer));
        deployer.setFactory(address(factory));

        factory.createPair(address(currency), address(altcoin));
        pair  = IHoyuPair(factory.getPair(address(currency), address(altcoin)));
        vault = IHoyuVault(pair.vault());

        // Seed AMM liquidity (skewed)
        currency.mint(address(this), 200_000e18);
        altcoin.mint(address(this), 1_000_000e18);
        currency.transfer(address(pair), 200_000e18);
        altcoin.transfer(address(pair), 1_000_000e18);
        pair.mint(address(this));

        // FUND THE VAULT WITH CURRENCY (CRITICAL INVARIANT)
        currency.mint(address(vault), 100_000e18);

        // Deposit collateral
        altcoin.mint(borrower, 500_000e18);
        vm.prank(borrower);
        altcoin.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(500_000e18, borrower);
    }

    function test_can_create_one_loan() external {
        // Log initial AMM price
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 priceWad = (uint256(r0) * 1e18) / uint256(r1);
        emit log_named_uint("AMM price (CUR/ALT, wad)", priceWad);

        // Take exactly one tiny loan
        vm.prank(borrower);
        vault.takeOutLoan(1e18, borrower, "");

        // Assert bitmap flipped
        uint256 bitmap = vault.loanBitmap();
        emit log_named_uint("loan bitmap", bitmap);

        assertTrue(bitmap != 0, "loan bitmap should be non-zero");
    }
}

