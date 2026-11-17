// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Order} from "../src/Order.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {FeeConfig} from "../handlers/FeeConfig.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

/// @notice Fresh accounts enter throughout each run; terminal records remain in the ledger.
contract RightsDriver is Test {
    uint256 public constant MAX_RIGHTS = 32;
    uint256 public constant PRICE = 1 ether;
    uint256 public constant PREMIUM = 0.2 ether;
    uint256 public constant FEE = 0.002 ether;
    uint256 public constant ROYALTY = 0.05 ether;
    uint256 public constant DEPOSIT = 0.1 ether;
    uint256 public constant START_BALANCE = 1_000 ether;

    Market public market = new Market();
    Rights public rights = market.rights();
    CoveredNFTPurchase public purchase = new CoveredNFTPurchase(market);
    RoyaltyNFT public nft = new RoyaltyNFT();
    address public issuer = makeAddr("issuer");
    address public royalty = makeAddr("royalty");
    address public feeCollector = makeAddr("feeCollector");
    address[3] public holders = [makeAddr("holder0"), makeAddr("holder1"), makeAddr("holder2")];
    FeeConfig public fees = new FeeConfig(market, makeAddr("feeAdmin"), feeCollector);
    NFTSale public sale = new NFTSale(fees);

    struct Entry {
        Right right;
        bytes config;
        uint256 nftId;
        uint256 deadline;
        address expectedHolder;
        address deliveredTo;
        bool nftDeposited;
        bool nftRecovered;
        uint256 ethDeposited;
        uint256 ethRecovered;
        uint256 issuerWithdrawn;
        uint256 royaltyWithdrawn;
        Order listing;
        bytes listingConfig;
        address listingSeller;
        bool listingClosed;
    }

    Entry[] internal entries;
    Order[] internal allListings;
    mapping(address actor => int256) public netEth;
    uint256 public premiumPaid;
    uint256 public premiumProceeds;
    uint256 public tradingFees;
    uint256 public created;
    uint256 public collateralDeposits;
    uint256 public activations;
    uint256 public transfers;
    uint256 public listings;
    uint256 public sales;
    uint256 public listingCancellations;
    uint256 public staleListingsClosed;
    uint256 public exercises;
    uint256 public surrenders;
    uint256 public expiries;
    uint256 public setupCancellations;
    uint256 public nftRecoveries;
    uint256 public ethRecoveries;
    uint256 public creditWithdrawals;
    uint256 public bypassAttempts;
    uint256 public skipped;
    bool public bypassSucceeded;

    constructor() {
        vm.warp(1_000_000);
        nft.setRoyalty(royalty, 500);
        vm.deal(issuer, START_BALANCE);
        vm.deal(royalty, START_BALANCE);
        vm.deal(feeCollector, 0);
        for (uint256 i; i < holders.length; ++i) {
            vm.deal(holders[i], START_BALANCE);
        }
        _create(1);
        _deposit(0);
        _activate(0);
        _create(2);
        _deposit(1);
    }

    function count() external view returns (uint256) {
        return entries.length;
    }

    function listingCount() external view returns (uint256) {
        return allListings.length;
    }

    function record(uint256 i) external view returns (Entry memory) {
        return entries[i];
    }

    function listingAt(uint256 i) external view returns (Order) {
        return allListings[i];
    }

    function _create(uint256 seed) private {
        uint256 id = entries.length + 1;
        uint256 deadline = seed % 4 == 0 ? 0 : block.timestamp + 7 days;
        nft.mint(issuer, id);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, id, PRICE, issuer, 500));
        vm.prank(issuer);
        Right right = market.createRight(purchase, config, deadline, issuer, bytes32(id));
        entries.push();
        Entry storage e = entries[entries.length - 1];
        e.right = right;
        e.config = config;
        e.nftId = id;
        e.deadline = deadline;
        created++;
    }

    function _deposit(uint256 i) private {
        Entry storage e = entries[i];
        vm.prank(issuer);
        nft.transferFrom(issuer, address(e.right), e.nftId);
        e.nftDeposited = true;
        collateralDeposits++;
    }

    function _activate(uint256 i) private {
        Entry storage e = entries[i];
        vm.prank(issuer);
        e.right.activate(e.config);
        e.expectedHolder = issuer;
        activations++;
    }

    function create(uint256 seed) external {
        if (entries.length == MAX_RIGHTS) {
            skipped++;
            return;
        }
        _create(seed);
    }

    function deposit(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 1);
        if (!found) {
            skipped++;
            return;
        }
        _deposit(i);
    }

    function activate(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 2);
        if (!found) {
            skipped++;
            return;
        }
        _activate(i);
    }

    function cancelSetup(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 3);
        if (!found) {
            skipped++;
            return;
        }
        vm.prank(issuer);
        entries[i].right.cancelSetup();
        setupCancellations++;
    }

    function fund(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 4);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        vm.prank(issuer);
        (bool ok,) = address(e.right).call{value: DEPOSIT}("");
        assertTrue(ok);
        e.ethDeposited += DEPOSIT;
        netEth[issuer] -= int256(DEPOSIT);
    }

    function transfer(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 5);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        address from = e.expectedHolder;
        address to = _otherActor(from, seed);
        uint256 id = e.right.tokenId();
        vm.prank(from);
        rights.transferFrom(from, to, id);
        e.expectedHolder = to;
        transfers++;
    }

    function list(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 6);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        address seller = e.expectedHolder;
        uint256 expiry = block.timestamp + 1 days;
        if (e.deadline != 0 && expiry >= e.deadline) expiry = e.deadline - 1 hours;
        bytes memory config = abi.encode(
            NFTSale.Config(
                rights,
                e.right.tokenId(),
                NFTTrade.Schedule(PREMIUM, PREMIUM, block.timestamp, block.timestamp, expiry),
                seller,
                0
            )
        );
        vm.startPrank(seller);
        Order order = market.create(sale, config, bytes32(uint256(10_000 + allListings.length)));
        rights.transferFrom(seller, address(order), e.right.tokenId());
        vm.stopPrank();
        e.listing = order;
        e.listingConfig = config;
        e.listingSeller = seller;
        e.listingClosed = false;
        e.expectedHolder = address(order);
        allListings.push(order);
        listings++;
    }

    function settleListing(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 7);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        NFTSale.Config memory c = abi.decode(e.listingConfig, (NFTSale.Config));
        bool saleLive = e.right.isLive() && block.timestamp < c.schedule.expiry;
        if (saleLive && seed % 2 == 0) {
            address buyer = _otherActor(e.listingSeller, seed);
            vm.prank(buyer);
            e.listing.fill{value: PREMIUM}(e.listingConfig, abi.encode(buyer, PREMIUM));
            e.expectedHolder = buyer;
            e.listingClosed = true;
            premiumPaid += PREMIUM;
            premiumProceeds += PREMIUM - FEE;
            tradingFees += FEE;
            netEth[buyer] -= int256(PREMIUM);
            netEth[e.listingSeller] += int256(PREMIUM - FEE);
            sales++;
        } else {
            vm.prank(e.listingSeller);
            e.listing.close();
            e.listingClosed = true;
            if (e.right.isLive()) {
                uint256 id = e.right.tokenId();
                vm.prank(e.listingSeller);
                e.listing
                    .execute(
                        address(rights),
                        0,
                        abi.encodeCall(IERC721.transferFrom, (address(e.listing), e.listingSeller, id))
                    );
                e.expectedHolder = e.listingSeller;
                listingCancellations++;
            } else {
                staleListingsClosed++;
            }
        }
    }

    function terminate(uint256 seed) external {
        if (seed % 4 == 3) {
            (uint256 i, bool found) = _pick(seed, 10);
            if (!found) {
                skipped++;
                return;
            }
            Entry storage e = entries[i];
            if (block.timestamp < e.deadline) vm.warp(e.deadline);
            e.right.finalizeExpiry();
            e.expectedHolder = address(0);
            expiries++;
            return;
        }
        (uint256 i, bool found) = _pick(seed, 8);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        address holder = e.expectedHolder;
        if (seed % 4 == 2) {
            vm.prank(holder);
            e.right.surrender();
            e.expectedHolder = address(0);
            surrenders++;
        } else {
            address recipient = _otherActor(holder, seed);
            vm.prank(holder);
            e.right.exercise{value: PRICE}(e.config, abi.encode(recipient));
            e.expectedHolder = address(0);
            e.deliveredTo = recipient;
            netEth[holder] -= int256(PRICE);
            exercises++;
        }
    }

    function recover(uint256 seed) external {
        if (seed % 2 == 0) {
            (uint256 i, bool found) = _pick(seed, 11);
            if (!found) {
                skipped++;
                return;
            }
            Entry storage e = entries[i];
            vm.prank(issuer);
            e.right.recover(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(e.right), issuer, e.nftId)));
            e.nftRecovered = true;
            nftRecoveries++;
        } else {
            (uint256 i, bool found) = _pick(seed, 12);
            if (!found) {
                skipped++;
                return;
            }
            Entry storage e = entries[i];
            uint256 amount = address(e.right).balance - e.right.totalCredits();
            vm.prank(issuer);
            e.right.recover(issuer, amount, "");
            e.ethRecovered += amount;
            netEth[issuer] += int256(amount);
            ethRecoveries++;
        }
    }

    function withdraw(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 13);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        address beneficiary = seed % 2 == 0 ? issuer : royalty;
        uint256 amount = e.right.creditOf(beneficiary);
        if (amount == 0) beneficiary = beneficiary == issuer ? royalty : issuer;
        amount = e.right.creditOf(beneficiary);
        if (seed % 4 == 0) {
            e.right.releaseCredit(beneficiary);
        } else {
            vm.prank(beneficiary);
            e.right.withdrawCredit(payable(beneficiary));
        }
        if (beneficiary == issuer) e.issuerWithdrawn += amount;
        else e.royaltyWithdrawn += amount;
        netEth[beneficiary] += int256(amount);
        creditWithdrawals++;
    }

    function attack(uint256 seed) external {
        (uint256 i, bool found) = _pick(seed, 14);
        if (!found) {
            skipped++;
            return;
        }
        Entry storage e = entries[i];
        vm.prank(issuer);
        (bool ok,) = address(e.right)
            .call(
                abi.encodeCall(
                    Right.execute,
                    (address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(e.right), issuer, e.nftId)))
                )
            );
        if (ok) bypassSucceeded = true;
        vm.prank(issuer);
        (ok,) = address(e.right)
            .call(
                abi.encodeCall(
                    Right.recover,
                    (address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(e.right), issuer, e.nftId)))
                )
            );
        if (ok) bypassSucceeded = true;
        if (e.expectedHolder != issuer) {
            vm.prank(issuer);
            (ok,) = address(e.right).call(abi.encodeCall(Right.surrender, ()));
            if (ok) bypassSucceeded = true;
        }
        bypassAttempts++;
    }

    function _actor(uint256 seed) private view returns (address) {
        uint256 n = seed % 4;
        return n == 0 ? issuer : holders[n - 1];
    }

    function _otherActor(address from, uint256 seed) private view returns (address) {
        address to = _actor(seed);
        if (to == from) to = _actor(seed % 4 + 1);
        return to;
    }

    function _isActor(address who) private view returns (bool) {
        if (who == issuer) return true;
        for (uint256 i; i < holders.length; ++i) {
            if (who == holders[i]) return true;
        }
        return false;
    }

    /// @dev A random start with a bounded scan finds useful states instead of hitting an old
    /// terminal record. Records are never recycled, and cap saturation is counted as skipped.
    function _pick(uint256 seed, uint8 action) private view returns (uint256 index, bool found) {
        uint256 n = entries.length;
        for (uint256 j; j < n; ++j) {
            uint256 i = (seed % n + j) % n;
            Entry storage e = entries[i];
            Right.State state = e.right.state();
            bool live = e.right.isLive();
            if (action == 1 && state == Right.State.Pending && !e.nftDeposited) return (i, true);
            if (
                action == 2 && state == Right.State.Pending && e.nftDeposited
                    && (e.deadline == 0 || block.timestamp < e.deadline)
            ) return (i, true);
            if (action == 3 && state == Right.State.Pending) return (i, true);
            if (action == 4 && (state == Right.State.Pending || state == Right.State.Active) && e.ethDeposited == 0) {
                return (i, true);
            }
            if (action == 5 && live && _isActor(e.expectedHolder)) return (i, true);
            if (
                action == 6 && live && _isActor(e.expectedHolder)
                    && (address(e.listing) == address(0) || e.listingClosed)
                    && (e.deadline == 0 || e.deadline > block.timestamp + 1 hours)
            ) return (i, true);
            if (action == 7 && address(e.listing) != address(0) && !e.listingClosed) return (i, true);
            if (action == 8 && live && _isActor(e.expectedHolder)) return (i, true);
            if (action == 10 && (state == Right.State.Pending || state == Right.State.Active) && e.deadline != 0) {
                return (i, true);
            }
            if (action == 11 && _terminal(state) && !e.nftRecovered && nft.ownerOf(e.nftId) == address(e.right)) {
                return (i, true);
            }
            if (action == 12 && _terminal(state) && address(e.right).balance > e.right.totalCredits()) {
                return (i, true);
            }
            if (action == 13 && e.right.totalCredits() != 0) return (i, true);
            if (action == 14 && state == Right.State.Active && nft.ownerOf(e.nftId) == address(e.right)) {
                return (i, true);
            }
        }
    }

    function _terminal(Right.State state) private pure returns (bool) {
        return state == Right.State.Exercised || state == Right.State.Expired || state == Right.State.Surrendered
            || state == Right.State.Canceled;
    }
}

contract RightsInvariantTest is StdInvariant, Test {
    RightsDriver driver;

    event CampaignMetrics(
        uint256 created,
        uint256 activated,
        uint256 sold,
        uint256 exercised,
        uint256 expired,
        uint256 surrendered,
        uint256 recoveredNft,
        uint256 withdrawnCredits,
        uint256 bypassAttempts,
        uint256 skipped
    );

    function setUp() public {
        driver = new RightsDriver();
        targetContract(address(driver));
    }

    /// @notice Proves the driver itself reaches every major transition with independent
    /// accounts, including claims left after the first right terminates.
    function test_driverReachesMultipleLifecycles() public {
        driver.list(0);
        driver.settleListing(0); // primary premium sale
        driver.transfer(1);
        driver.terminate(0); // exercise, then both credited beneficiaries withdraw
        driver.withdraw(0);
        driver.withdraw(1);

        driver.create(3);
        driver.deposit(2);
        driver.activate(2);
        driver.terminate(2); // surrender, then recover NFT
        driver.recover(2);
        driver.cancelSetup(1); // already backed pending setup
        driver.recover(0);

        driver.create(1);
        driver.deposit(3);
        driver.activate(3);
        driver.fund(3);
        driver.terminate(3); // expiry, then recover unused ETH and NFT
        driver.recover(3);
        driver.recover(2);

        driver.create(0); // perpetual claim
        driver.deposit(4);
        driver.activate(4);
        driver.list(4);
        driver.settleListing(5); // cancellation returns token
        driver.attack(4);
        driver.transfer(4);
        driver.attack(4); // issuer now differs from holder
        driver.list(4);
        driver.settleListing(4); // resale
        driver.terminate(4);

        invariant_collateralAndEntitlement();
        invariant_ethAndPaymentLiabilities();
        assertGe(driver.created(), 5);
        assertGe(driver.activations(), 4);
        assertGe(driver.sales(), 2);
        assertGe(driver.listingCancellations(), 1);
        assertGe(driver.exercises(), 2);
        assertGe(driver.surrenders(), 1);
        assertGe(driver.expiries(), 1);
        assertGe(driver.setupCancellations(), 1);
        assertGe(driver.nftRecoveries(), 2);
        assertGe(driver.ethRecoveries(), 1);
        assertGe(driver.creditWithdrawals(), 2);
        assertGe(driver.bypassAttempts(), 2);
        assertEq(driver.skipped(), 0, "deterministic sequence reached every selected transition");
    }

    function invariant_collateralAndEntitlement() public view {
        uint256 n = driver.count();
        Rights rights = driver.rights();
        RoyaltyNFT nft = driver.nft();
        for (uint256 i; i < n; ++i) {
            RightsDriver.Entry memory e = driver.record(i);
            Right.State state = e.right.state();
            uint256 id = e.right.tokenId();
            assertEq(e.right.residual(), driver.issuer());
            assertEq(e.right.issuer(), driver.issuer());
            assertEq(e.right.deadline(), e.deadline);
            assertEq(e.right.configHash(), keccak256(e.config));
            if (state == Right.State.Active) {
                assertEq(nft.ownerOf(e.nftId), address(e.right), "active collateral");
                assertEq(rights.ownerOf(id), e.expectedHolder, "active token exists, even after deadline");
                assertTrue(rights.everMinted(id));
                assertEq(e.right.totalCredits(), 0);
            } else {
                // ownerOf must revert for pending and every terminal state.
                bool exists;
                try rights.ownerOf(id) returns (address) {
                    exists = true;
                } catch {}
                assertFalse(exists, "inactive token exists");
                if (state == Right.State.Exercised) {
                    assertEq(nft.ownerOf(e.nftId), e.deliveredTo, "exercise delivered NFT");
                } else {
                    assertEq(
                        nft.ownerOf(e.nftId),
                        e.nftRecovered ? driver.issuer() : e.nftDeposited ? address(e.right) : driver.issuer(),
                        "collateral destination"
                    );
                }
            }
        }
        assertFalse(driver.bypassSucceeded());
    }

    function invariant_ethAndPaymentLiabilities() public view {
        uint256 n = driver.count();
        uint256 held;
        uint256 totalCredits;
        for (uint256 i; i < n; ++i) {
            RightsDriver.Entry memory e = driver.record(i);
            uint256 issuerCredit = e.right.creditOf(driver.issuer());
            uint256 royaltyCredit = e.right.creditOf(driver.royalty());
            uint256 credits = issuerCredit + royaltyCredit;
            assertEq(credits, e.right.totalCredits(), "isolated credits reconcile");
            assertLe(credits, address(e.right).balance, "credits remain funded");
            assertLe(e.ethRecovered, e.ethDeposited, "residual cannot take exercise liabilities");
            if (e.right.state() == Right.State.Exercised) {
                assertEq(issuerCredit + e.issuerWithdrawn, 0.95 ether, "absolute issuer credit");
                assertEq(royaltyCredit + e.royaltyWithdrawn, 0.05 ether, "absolute royalty credit");
            } else {
                assertEq(credits + e.issuerWithdrawn + e.royaltyWithdrawn, 0);
            }
            assertEq(address(e.right).balance, e.ethDeposited - e.ethRecovered + credits, "account ETH destination");
            held += address(e.right).balance;
            totalCredits += credits;
        }
        assertLe(totalCredits, held);
        assertEq(driver.premiumPaid(), driver.premiumProceeds() + driver.tradingFees());
        assertEq(driver.premiumPaid(), driver.sales() * 0.2 ether, "absolute premium per sale");
        assertEq(driver.premiumProceeds(), driver.sales() * 0.198 ether, "absolute seller premium");
        assertEq(driver.tradingFees(), driver.sales() * 0.002 ether, "absolute trading fee");
        assertEq(driver.feeCollector().balance, driver.tradingFees(), "fee recipient balance");
        for (uint256 i; i < driver.listingCount(); ++i) {
            assertEq(address(driver.listingAt(i)).balance, 0, "listing retains no ETH");
        }
        assertEq(driver.issuer().balance, uint256(int256(driver.START_BALANCE()) + driver.netEth(driver.issuer())));
        for (uint256 i; i < 3; ++i) {
            address actor = driver.holders(i);
            assertEq(actor.balance, uint256(int256(driver.START_BALANCE()) + driver.netEth(actor)));
        }
        assertEq(driver.royalty().balance, uint256(int256(driver.START_BALANCE()) + driver.netEth(driver.royalty())));
    }

    /// @notice Foundry calls this after each invariant run; events expose reached transitions.
    function afterInvariant() public {
        emit log_named_uint("rights created", driver.created());
        emit log_named_uint("rights activated", driver.activations());
        emit log_named_uint("rights transferred", driver.transfers());
        emit log_named_uint("rights listed", driver.listings());
        emit log_named_uint("rights sold", driver.sales());
        emit log_named_uint("rights listing cancels", driver.listingCancellations());
        emit log_named_uint("rights exercised", driver.exercises());
        emit log_named_uint("rights expired", driver.expiries());
        emit log_named_uint("rights surrendered", driver.surrenders());
        emit log_named_uint("rights recovered", driver.nftRecoveries());
        emit log_named_uint("rights credit withdrawals", driver.creditWithdrawals());
        emit log_named_uint("rights bypass attempts", driver.bypassAttempts());
        emit log_named_uint("rights skipped", driver.skipped());
        emit CampaignMetrics(
            driver.created(),
            driver.activations(),
            driver.sales(),
            driver.exercises(),
            driver.expiries(),
            driver.surrenders(),
            driver.nftRecoveries(),
            driver.creditWithdrawals(),
            driver.bypassAttempts(),
            driver.skipped()
        );
    }
}
