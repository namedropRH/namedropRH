// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal surface of the launchpad's V2 contracts, taken from its verified source
/// (PonsV2LaunchFactory 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e on chain 4663).
/// Only what DropVault actually calls is declared here.

interface IPonsFeeEscrow {
    function balanceOf(address account) external view returns (uint256);
    function balanceOfToken(address account, address token) external view returns (uint256);
    /// Pays the caller with `.call`, so a contract recipient with logic in receive() is fine.
    function claim() external;
    function claimToken(address token) external;
}

interface IPonsSweep {
    /// The curve pays the creator share to its `deployer`, which the venue sets to the
    /// creator FEE RECIPIENT — i.e. the vault. So the vault is who may sweep.
    /// The venue itself blocks this path when an internal swap is required, which is the
    /// only case where the slippage floor could be abused.
    function sweepFees(uint256 minBuybackTokensOut) external;
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsLaunchFactory {
    /// Only the CURRENT creator fee recipient may hand the role on.
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function setBuybackEnabled(address token, bool enabled) external;
}

/// Only the pieces the fork test drives. Kept separate from what DropVault calls so the
/// production contract's dependency surface stays as small as it looks.
interface IPonsFactoryFull {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchFee() external view returns (uint256);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    /// Callable by the launchpad's sweep operator or by the coin's deployer.
    function sweepFees(uint256 minBuybackTokensOut) external;
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function graduated() external view returns (bool);
}
