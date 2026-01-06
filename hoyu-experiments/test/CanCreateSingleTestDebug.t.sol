// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {HoyuFactory} from "../src/HoyuFactory.sol";
import {HoyuVaultDeployer} from "../src/HoyuVaultDeployer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IHoyuPair {
    function mint(address to) external returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
    function vault() external view returns (address);
}

interface IHoyuVault {
    function depositCollateral(uint256 amount, address to) external;
    function takeOutLoan(uint256 amount, address to, bytes calldata data) external;
    function loanBitmap() external view returns (uint256);
}

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract CanCreateSingleLoan_Debug is Test {
    MockERC20 currency;
    MockERC20 altcoin;

    HoyuFactory factory;
    HoyuVaultDeployer deployer;

    IHoyuPair pair;
    IHoyuVault vault;

    address borrower = address(0xA11CE);

    function setUp() external {
        currency = new MockERC20("Currency", "CUR");
        altcoin  = new MockERC20("Altcoin",  "ALT");

        deployer = new HoyuVaultDeployer();
        factory  = new HoyuFactory(address(deployer));
        deployer.setFactory(address(factory));

        factory.createPair(address(currency), address(altcoin));
        pair  = IHoyuPair(factory.getPair(address(currency), address(altcoin)));
        vault = IHoyuVault(pair.vault());

        // AMM liquidity
        currency.mint(address(this), 200_000e18);
        altcoin.mint(address(this), 1_000_000e18);
        currency.transfer(address(pair), 200_000e18);
        altcoin.transfer(address(pair), 1_000_000e18);
        pair.mint(address(this));

        // FUND VAULT
        currency.mint(address(vault), 200_000e18);

        // Collateral
        altcoin.mint(borrower, 500_000e18);
        vm.prank(borrower);
        altcoin.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(500_000e18, borrower);
    }

    function test_debug_single_loan() external {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        emit log_named_uint("price (wad)", (uint256(r0) * 1e18) / uint256(r1));

        uint256;
        amounts[0] = 1e18;
        amounts[1] = 10e18;
        amounts[2] = 100e18;
        amounts[3] = 1_000e18;

        bytes;
        payloads[0] = "";
        payloads[1] = abi.encode(uint256(1)); // non-empty callback hint

        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 j = 0; j < payloads.length; j++) {
                uint256 snap = vm.snapshot();
                vm.prank(borrower);

                try vault.takeOutLoan(amounts[i], borrower, payloads[j]) {
                    emit log_named_uint("SUCCESS loan amount", amounts[i]);
                    emit log_named_uint("bitmap", vault.loanBitmap());
                    return;
                } catch (bytes memory err) {
                    emit log("REVERT");
                    emit log_named_uint("amount", amounts[i]);
                    emit log_named_uint("payload_len", payloads[j].length);
                    emit log_named_bytes("error", err);
                }

                vm.revertTo(snap);
            }
        }

        fail("No borrow configuration succeeded");
    }
}

