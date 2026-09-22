// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Stands in for the launchpad escrow: credit() holds value per recipient, claim() pays
/// the caller with .call, exactly as the real one does.
contract MockEscrow {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public balanceOfToken;

    function credit(address to) external payable {
        balanceOf[to] += msg.value;
    }

    function creditToken(address to, address token, uint256 amount) external {
        balanceOfToken[to][token] += amount;
    }

    function claim() external {
        uint256 amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "escrow: native transfer failed");
    }

    function claimToken(address token) external {
        uint256 amount = balanceOfToken[msg.sender][token];
        balanceOfToken[msg.sender][token] = 0;
        MockERC20(token).transfer(msg.sender, amount);
    }

    receive() external payable {}
}

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A treasury that refuses payment, to prove a hostile treasury cannot hold a recipient hostage.
contract RejectingTreasury {
    receive() external payable {
        revert("no");
    }
}
