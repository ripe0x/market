// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Market, IPricingStrategy, ISaleObserver} from "../contracts/Market.sol";

/// WETH9 semantics: max allowance is not decremented.
contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// ERC20 with optional fee on transfer and optional missing return value (USDT style).
contract MockToken is MockWETH {
    uint256 public feeBps;
    bool public noReturn;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(uint256 feeBps_, bool noReturn_) external {
        (feeBps, noReturn) = (feeBps_, noReturn_);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount * feeBps / 10_000;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _move(from, to, amount);
        if (noReturn) {
            assembly { return(0, 0) }
        }
        return true;
    }
}

interface IReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// Minimal ERC721 with switchable ERC-2981 royalty and sale observer behavior.
contract MockNFT {
    enum Observer {
        None,
        Record,
        Revert,
        BurnGas,
        Reenter
    }

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    address public royaltyReceiver;
    uint256 public royaltyBps;
    uint256 public royaltyFixed; // added to the proportional amount: not proportional
    Observer public observer;
    uint256 public sales;
    uint256 public lastPrice;
    address public lastBuyer;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setRoyalty(address receiver, uint256 bps, uint256 fixedAmount) external {
        (royaltyReceiver, royaltyBps, royaltyFixed) = (receiver, bps, fixedAmount);
    }

    function setObserver(Observer o) external {
        observer = o;
    }

    function approve(address to, uint256 id) external {
        require(msg.sender == ownerOf[id] || isApprovedForAll[ownerOf[id]][msg.sender], "not owner");
        getApproved[id] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "not from");
        require(
            msg.sender == from || getApproved[id] == msg.sender || isApprovedForAll[from][msg.sender], "not approved"
        );
        require(to != address(0), "zero");
        delete getApproved[id];
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external {
        transferFrom(from, to, id);
        if (to.code.length != 0) {
            require(IReceiver(to).onERC721Received(msg.sender, from, id, data) == IReceiver.onERC721Received.selector);
        }
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        return id == 0x01ffc9a7 || (id == 0x2a55205a && royaltyReceiver != address(0))
            || (id == ISaleObserver.onMarketSale.selector && observer != Observer.None);
    }

    function royaltyInfo(uint256, uint256 price) external view returns (address, uint256) {
        return (royaltyReceiver, price * royaltyBps / 10_000 + royaltyFixed);
    }

    function onMarketSale(uint256, address, address buyer, address, uint256 price) external {
        if (observer == Observer.Revert) revert("observer");
        if (observer == Observer.BurnGas) {
            while (true) {}
        }
        if (observer == Observer.Reenter) {
            Market.Bid memory b;
            Market(msg.sender).createBid(b); // must hit the lock
        }
        sales++;
        lastPrice = price;
        lastBuyer = buyer;
    }
}

contract MockStrategy is IPricingStrategy {
    uint256 public value;
    uint256 public step; // added per completed fill
    bool public fail;

    function set(uint256 value_, uint256 step_, bool fail_) external {
        (value, step, fail) = (value_, step_, fail_);
    }

    function price(uint256, bool, address, uint256, uint256 fills, bytes32) external view returns (uint256) {
        require(!fail, "strategy");
        return value + step * fills;
    }
}
