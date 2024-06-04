// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestContracts/WETH.sol";
import "../TestContracts/MockUSDT.sol";
import "../libraries/SignatureUtils.sol";

import "src/marketplace/MichiMarketplace.sol";
import "src/MichiWalletNFT.sol";
import {Order, Listing, Offer} from "src/libraries/OrderTypes.sol";
import "src/libraries/SignatureAuthentication.sol";

contract MarketplaceTest is Test {
    MichiMarketplace public marketplace;
    MichiWalletNFT public michiWalletNFT;
    WETH public weth;
    MockUSDT public usdt;
    SignatureUtils public sigUtils;

    uint256 internal user1PrivateKey;
    uint256 internal user2PrivateKey;

    address internal user1;
    address internal user2;

    address internal feeReceiver;

    struct ListingOrder {
        address seller;
        address collection;
        address currency;
        uint256 tokenId;
        uint256 amount;
        uint256 expiry;
        uint256 nonce;
    }

    struct OfferOrder {
        address buyer;
        address collection;
        address currency;
        uint256 tokenId;
        uint256 amount;
        uint256 expiry;
        uint256 nonce;
    }

    function setUp() public {
        feeReceiver = vm.addr(10);
        weth = new WETH();
        usdt = new MockUSDT();
        michiWalletNFT = new MichiWalletNFT(0, 0);
        marketplace = new MichiMarketplace(address(weth), feeReceiver, 100, 10000);
        sigUtils = new SignatureUtils(marketplace.domainSeparator());

        marketplace.addAcceptedCurrency(address(weth));
        marketplace.addAcceptedCurrency(address(usdt));
        marketplace.addAcceptedCollection(address(michiWalletNFT));

        user1PrivateKey = 0x1;
        user2PrivateKey = 0x2;

        user1 = vm.addr(user1PrivateKey);
        user2 = vm.addr(user2PrivateKey);

        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);

        vm.prank(user1);
        weth.deposit{value: 100 ether}();
        vm.prank(user2);
        weth.deposit{value: 100 ether}();

        usdt.mint(user1, 100000e18);
        usdt.mint(user2, 100000e18);

        michiWalletNFT.mint(user1); // tokenId 0
        michiWalletNFT.mint(user1); // tokenId 1
    }

    function testExecuteListingETH() public {
        // user1 creates weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest = sigUtils.getTypedListingHash(wethListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, wethListingDigest);

        uint256 sellerBalance = user1.balance;

        uint256 fee = marketplace.marketplaceFee();
        uint256 precision = marketplace.precision();
        uint256 expectedFees = wethListing.amount * fee / precision;
        uint256 paymentAmountAfterFees = wethListing.amount - expectedFees;

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: wethListing.collection,
                currency: wethListing.currency,
                tokenId: wethListing.tokenId,
                amount: wethListing.amount,
                expiry: wethListing.expiry
            }),
            seller: wethListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: wethListing.nonce
        });

        // user2 purchases listing
        vm.prank(user2);
        marketplace.executeListing{value: wethListing.amount}(signedListing);

        //verify that payment, fees, and NFT are transferred correctly
        assertEq(user1.balance, sellerBalance + paymentAmountAfterFees);
        assertEq(michiWalletNFT.ownerOf(wethListing.tokenId), user2);
        assertEq((marketplace.marketplaceFeeRecipient()).balance, expectedFees);

        //verify that listing/nonce cannot be reused
        //first transfer wallet back to lister
        vm.prank(user2);
        michiWalletNFT.transferFrom(user2, user1, wethListing.tokenId);

        address user3 = vm.addr(3);
        vm.deal(user3, 100 ether);

        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.executeListing{value: wethListing.amount}(signedListing);
    }

    function testExecuteListingERC20() public {
        // user1 creates usdt listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory usdtListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: 10000e18,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtListingDigest = sigUtils.getTypedListingHash(usdtListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, usdtListingDigest);

        uint256 sellerUSDTBalance = usdt.balanceOf(user1);

        uint256 fee = marketplace.marketplaceFee();
        uint256 precision = marketplace.precision();
        uint256 expectedFees = usdtListing.amount * fee / precision;
        uint256 paymentAmountAfterFees = usdtListing.amount - expectedFees;

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: usdtListing.collection,
                currency: usdtListing.currency,
                tokenId: usdtListing.tokenId,
                amount: usdtListing.amount,
                expiry: usdtListing.expiry
            }),
            seller: usdtListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: usdtListing.nonce
        });

        // user2 approves usdt
        vm.prank(user2);
        usdt.approve(address(marketplace), usdtListing.amount);
        // user2 purchases listing
        vm.prank(user2);
        marketplace.executeListing{value: 0}(signedListing);

        //verify that payment, fees, and NFT are transferred correctly
        assertEq(usdt.balanceOf(user1), sellerUSDTBalance + paymentAmountAfterFees);
        assertEq(michiWalletNFT.ownerOf(usdtListing.tokenId), user2);
        assertEq(usdt.balanceOf(marketplace.marketplaceFeeRecipient()), expectedFees);
    }

    function testAcceptOffer() public {
        // user2 creates offer to buy user 1's wallet #0
        uint256 offerAmount = 10000e18;
        vm.prank(user2);
        usdt.approve(address(marketplace), offerAmount);

        SignatureUtils.Offer memory usdtOffer = SignatureUtils.Offer({
            buyer: user2,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: offerAmount,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtOfferDigest = sigUtils.getTypedOfferHash(usdtOffer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2PrivateKey, usdtOfferDigest);

        uint256 sellerUSDTBalance = usdt.balanceOf(user1);

        uint256 fee = marketplace.marketplaceFee();
        uint256 precision = marketplace.precision();
        uint256 expectedFees = usdtOffer.amount * fee / precision;
        uint256 paymentAmountAfterFees = usdtOffer.amount - expectedFees;

        // create signed offer struct
        Offer memory signedOffer = Offer({
            order: Order({
                collection: usdtOffer.collection,
                currency: usdtOffer.currency,
                tokenId: usdtOffer.tokenId,
                amount: usdtOffer.amount,
                expiry: usdtOffer.expiry
            }),
            buyer: usdtOffer.buyer,
            v: v,
            r: r,
            s: s,
            nonce: usdtOffer.nonce
        });

        // user1 accepts offer
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        vm.prank(user1);
        marketplace.acceptOffer(signedOffer);

        //verify that payment, fees, and NFT are transferred correctly
        assertEq(usdt.balanceOf(user1), sellerUSDTBalance + paymentAmountAfterFees);
        assertEq(michiWalletNFT.ownerOf(usdtOffer.tokenId), user2);
        assertEq(usdt.balanceOf(marketplace.marketplaceFeeRecipient()), expectedFees);
    }

    function testCancelListing() public {
        // user1 creates weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest = sigUtils.getTypedListingHash(wethListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, wethListingDigest);

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: wethListing.collection,
                currency: wethListing.currency,
                tokenId: wethListing.tokenId,
                amount: wethListing.amount,
                expiry: wethListing.expiry
            }),
            seller: wethListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: wethListing.nonce
        });

        // user1 cancels listing
        uint256[] memory a = new uint256[](1);
        a[0] = wethListing.nonce;
        vm.prank(user1);
        marketplace.cancelOrdersForCaller(a);

        // user2 cannot execute listing
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.executeListing{value: wethListing.amount}(signedListing);
    }

    function testCancelMultipleListings() public {
        // user1 creates first weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing1 = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest1 = sigUtils.getTypedListingHash(wethListing1);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(user1PrivateKey, wethListingDigest1);

        // create signed listing struct
        Listing memory signedListing1 = Listing({
            order: Order({
                collection: wethListing1.collection,
                currency: wethListing1.currency,
                tokenId: wethListing1.tokenId,
                amount: wethListing1.amount,
                expiry: wethListing1.expiry
            }),
            seller: wethListing1.seller,
            v: v1,
            r: r1,
            s: s1,
            nonce: wethListing1.nonce
        });

        // user1 created second weth listing
        SignatureUtils.Listing memory wethListing2 = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 1,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 2
        });

        bytes32 wethListingDigest2 = sigUtils.getTypedListingHash(wethListing2);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(user1PrivateKey, wethListingDigest2);

        // create signed listing struct
        Listing memory signedListing2 = Listing({
            order: Order({
                collection: wethListing2.collection,
                currency: wethListing2.currency,
                tokenId: wethListing2.tokenId,
                amount: wethListing2.amount,
                expiry: wethListing2.expiry
            }),
            seller: wethListing2.seller,
            v: v2,
            r: r2,
            s: s2,
            nonce: wethListing2.nonce
        });

        // user1 cancels both listings
        vm.prank(user1);
        marketplace.cancelAllOrdersForCaller(wethListing2.nonce);

        // user2 cannot execute either listing
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.executeListing{value: wethListing1.amount}(signedListing1);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.executeListing{value: wethListing2.amount}(signedListing2);
    }

    function testCancelOffer() public {
        // user2 creates offer to buy user 1's wallet #0
        uint256 offerAmount = 10000e18;
        vm.prank(user2);
        usdt.approve(address(marketplace), offerAmount);

        SignatureUtils.Offer memory usdtOffer = SignatureUtils.Offer({
            buyer: user2,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: offerAmount,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtOfferDigest = sigUtils.getTypedOfferHash(usdtOffer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2PrivateKey, usdtOfferDigest);

        // create signed offer struct
        Offer memory signedOffer = Offer({
            order: Order({
                collection: usdtOffer.collection,
                currency: usdtOffer.currency,
                tokenId: usdtOffer.tokenId,
                amount: usdtOffer.amount,
                expiry: usdtOffer.expiry
            }),
            buyer: usdtOffer.buyer,
            v: v,
            r: r,
            s: s,
            nonce: usdtOffer.nonce
        });

        // user2 cancels offer
        uint256[] memory a = new uint256[](1);
        a[0] = usdtOffer.nonce;
        vm.prank(user2);
        marketplace.cancelOrdersForCaller(a);

        // user1 cannot accept offer
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.acceptOffer(signedOffer);
    }

    function testCancelMultipleOffers() public {
        // user2 creates offer to buy user 1's wallet #0
        uint256 offerAmount = 10000e18;
        vm.prank(user2);
        usdt.approve(address(marketplace), offerAmount);

        SignatureUtils.Offer memory usdtOffer1 = SignatureUtils.Offer({
            buyer: user2,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: offerAmount,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtOfferDigest1 = sigUtils.getTypedOfferHash(usdtOffer1);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(user2PrivateKey, usdtOfferDigest1);

        // create signed offer struct
        Offer memory signedOffer1 = Offer({
            order: Order({
                collection: usdtOffer1.collection,
                currency: usdtOffer1.currency,
                tokenId: usdtOffer1.tokenId,
                amount: usdtOffer1.amount,
                expiry: usdtOffer1.expiry
            }),
            buyer: usdtOffer1.buyer,
            v: v1,
            r: r1,
            s: s1,
            nonce: usdtOffer1.nonce
        });

        // user2 creates offer to buy user 1's wallet #1
        SignatureUtils.Offer memory usdtOffer2 = SignatureUtils.Offer({
            buyer: user2,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 1,
            amount: offerAmount,
            expiry: block.timestamp + 1 days,
            nonce: 2
        });

        bytes32 usdtOfferDigest2 = sigUtils.getTypedOfferHash(usdtOffer2);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(user2PrivateKey, usdtOfferDigest2);

        // create signed offer struct
        Offer memory signedOffer2 = Offer({
            order: Order({
                collection: usdtOffer2.collection,
                currency: usdtOffer2.currency,
                tokenId: usdtOffer2.tokenId,
                amount: usdtOffer2.amount,
                expiry: usdtOffer2.expiry
            }),
            buyer: usdtOffer2.buyer,
            v: v2,
            r: r2,
            s: s2,
            nonce: usdtOffer2.nonce
        });

        // user2 cancels offers
        vm.prank(user2);
        marketplace.cancelAllOrdersForCaller(usdtOffer2.nonce);

        // user1 cannot accepts either offer
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.acceptOffer(signedOffer1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidOrder.selector));
        marketplace.acceptOffer(signedOffer2);
    }

    function testNotAcceptedCurrency() public {
        // remove usdt from accepted currencies
        marketplace.removeAcceptedCurrency(address(usdt));

        // user2 creates offer to buy user 1's wallet #0
        uint256 offerAmount = 10000e18;
        vm.prank(user2);
        usdt.approve(address(marketplace), offerAmount);

        SignatureUtils.Offer memory usdtOffer = SignatureUtils.Offer({
            buyer: user2,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: offerAmount,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtOfferDigest = sigUtils.getTypedOfferHash(usdtOffer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2PrivateKey, usdtOfferDigest);

        // create signed offer struct
        Offer memory signedOffer = Offer({
            order: Order({
                collection: usdtOffer.collection,
                currency: usdtOffer.currency,
                tokenId: usdtOffer.tokenId,
                amount: usdtOffer.amount,
                expiry: usdtOffer.expiry
            }),
            buyer: usdtOffer.buyer,
            v: v,
            r: r,
            s: s,
            nonce: usdtOffer.nonce
        });

        // user1 cannot accept offer as usdt is not accepted
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.CurrencyNotAccepted.selector));
        marketplace.acceptOffer(signedOffer);
    }

    function testNotAcceptedCollection() public {
        //remove michi wallet from accepted collections
        marketplace.removeAcceptedCollection(address(michiWalletNFT));

        // user2 creates offer to buy user 1's wallet #0
        uint256 offerAmount = 10000e18;
        vm.prank(user2);
        usdt.approve(address(marketplace), offerAmount);

        SignatureUtils.Offer memory usdtOffer = SignatureUtils.Offer({
            buyer: user2,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: offerAmount,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtOfferDigest = sigUtils.getTypedOfferHash(usdtOffer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2PrivateKey, usdtOfferDigest);

        // create signed offer struct
        Offer memory signedOffer = Offer({
            order: Order({
                collection: usdtOffer.collection,
                currency: usdtOffer.currency,
                tokenId: usdtOffer.tokenId,
                amount: usdtOffer.amount,
                expiry: usdtOffer.expiry
            }),
            buyer: usdtOffer.buyer,
            v: v,
            r: r,
            s: s,
            nonce: usdtOffer.nonce
        });

        // user1 cannot accept offer as michi wallet nft is not accepted
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.CollectionNotAccepted.selector));
        marketplace.acceptOffer(signedOffer);
    }

    function testCancellingOrders() public {
        // assume user1 has already created 3 offers of nonces 1, 2, and 3
        // user1 cancels orders 1 and 2
        vm.prank(user1);
        marketplace.cancelAllOrdersForCaller(2);

        // user1 tries to cancel orders 1 and 2 again
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.NonceLowerThanCurrent.selector));
        marketplace.cancelAllOrdersForCaller(2);

        // user1 cancels order 3
        uint256[] memory a = new uint256[](1);
        a[0] = 3;
        vm.prank(user1);
        marketplace.cancelOrdersForCaller(a);

        // user1 tries to cancel order 3 again
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.OrderAlreadyCancelled.selector));
        marketplace.cancelOrdersForCaller(a);
    }

    function testSellerNotOwner() public {
        // user1 creates weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest = sigUtils.getTypedListingHash(wethListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, wethListingDigest);

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: wethListing.collection,
                currency: wethListing.currency,
                tokenId: wethListing.tokenId,
                amount: wethListing.amount,
                expiry: wethListing.expiry
            }),
            seller: wethListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: wethListing.nonce
        });

        // user1 transfers wallet away
        vm.prank(user1);
        michiWalletNFT.transferFrom(user1, user2, wethListing.tokenId);

        // user2 purchases listing
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.SellerNotOwner.selector));
        marketplace.executeListing{value: wethListing.amount}(signedListing);
    }

    function testOrderExpired() public {
        // user1 creates weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest = sigUtils.getTypedListingHash(wethListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, wethListingDigest);

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: wethListing.collection,
                currency: wethListing.currency,
                tokenId: wethListing.tokenId,
                amount: wethListing.amount,
                expiry: wethListing.expiry
            }),
            seller: wethListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: wethListing.nonce
        });

        // set time to 2 days later
        vm.warp(block.timestamp + 2 days);

        // user2 purchases listing
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.OrderExpired.selector));
        marketplace.executeListing{value: wethListing.amount}(signedListing);
    }

    function testCurrencyMismatchETH() public {
        // user1 creates usdt listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory usdtListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(usdt),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 usdtListingDigest = sigUtils.getTypedListingHash(usdtListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, usdtListingDigest);

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: usdtListing.collection,
                currency: usdtListing.currency,
                tokenId: usdtListing.tokenId,
                amount: usdtListing.amount,
                expiry: usdtListing.expiry
            }),
            seller: usdtListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: usdtListing.nonce
        });

        // user tries to execute usdt listing with executeListingETH
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.CurrencyMismatch.selector));
        marketplace.executeListing{value: usdtListing.amount}(signedListing);
    }

    function testPaymentMismatch() public {
        // user1 creates weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest = sigUtils.getTypedListingHash(wethListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, wethListingDigest);

        // create signed listing struct
        Listing memory signedListing = Listing({
            order: Order({
                collection: wethListing.collection,
                currency: wethListing.currency,
                tokenId: wethListing.tokenId,
                amount: wethListing.amount,
                expiry: wethListing.expiry
            }),
            seller: wethListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: wethListing.nonce
        });

        // user2 tries to purchase listing with wrong msg.value
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.PaymentMismatch.selector));
        marketplace.executeListing{value: wethListing.amount / 2}(signedListing);
    }

    function testInvalidSignature() public {
        // user1 creates weth listing
        vm.prank(user1);
        michiWalletNFT.setApprovalForAll(address(marketplace), true);

        SignatureUtils.Listing memory wethListing = SignatureUtils.Listing({
            seller: user1,
            collection: address(michiWalletNFT),
            currency: address(weth),
            tokenId: 0,
            amount: 1 ether,
            expiry: block.timestamp + 1 days,
            nonce: 1
        });

        bytes32 wethListingDigest = sigUtils.getTypedListingHash(wethListing);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, wethListingDigest);

        // create signed listing struct with wrong parameters
        Listing memory signedListing = Listing({
            order: Order({
                collection: wethListing.collection,
                currency: wethListing.currency,
                tokenId: wethListing.tokenId,
                amount: wethListing.amount * 2,
                expiry: wethListing.expiry
            }),
            seller: wethListing.seller,
            v: v,
            r: r,
            s: s,
            nonce: wethListing.nonce
        });

        // user2 tries to purchase listing with wrong parameters
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.SignatureInvalid.selector));
        marketplace.executeListing{value: wethListing.amount * 2}(signedListing);
    }

    function testInvalidAddress() public {
        // try setting fee recipient to zero address
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidAddress.selector));
        marketplace.setMarketplaceFeeRecipient(address(0));

        // try setting fee recipient to current fee receiver
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidAddress.selector));
        marketplace.setMarketplaceFeeRecipient(feeReceiver);

        // try adding zero address to accepted currencies
        vm.expectRevert(abi.encodeWithSelector(IMichiMarketplace.InvalidAddress.selector));
        marketplace.addAcceptedCurrency(address(0));
    }
}
