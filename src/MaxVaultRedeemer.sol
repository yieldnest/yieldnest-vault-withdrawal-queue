// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import { IRedemptionAssetsVault } from "src/interfaces/IRedemptionAssetsVault.sol";
import { RedemptionVault } from "src/RedemptionVault.sol";
import { IBaseStrategy } from "lib/yieldnest-vault/src/interface/IBaseStrategy.sol";
import { IVault } from "lib/yieldnest-vault/src/interface/IVault.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract MaxVaultRedeemer is IRedemptionAssetsVault {
    error ZeroVault();
    error ZeroAsset();
    error NotEnoughLiquidityToFulfillRedemption();

    IBaseStrategy public immutable redemptionVault;
    IVault public immutable vault;
    address public immutable asset;

    address[] public redeemableAssets;
    address public owner;

    error NotOwner();
    error InvalidAsset(address asset);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _redemptionVault,
        address _vault,
        address _asset,
        address[] memory _redeemableAssets,
        address _owner
    ) {
        if (_redemptionVault == address(0)) revert ZeroVault();
        if (_vault == address(0)) revert ZeroVault();
        if (_asset == address(0)) revert ZeroAsset();
        if (_owner == address(0)) revert NotOwner();
        redemptionVault = IBaseStrategy(_redemptionVault);
        vault = IVault(_vault);
        asset = _asset;
        owner = _owner;
        setRedeemableAssets(_redeemableAssets);
    }

    /**
     * @notice Sets the list of redeemable assets. Permissioned, owner only. Each asset must be a valid asset for both
     * vault and redemptionVault.
     * @param _redeemableAssets Array of asset addresses to set as redeemable.
     */
    function setRedeemableAssets(address[] memory _redeemableAssets) public onlyOwner {
        delete redeemableAssets;
        for (uint256 i = 0; i < _redeemableAssets.length; ++i) {
            address asset_ = _redeemableAssets[i];
            if (!vault.hasAsset(asset_) || !IVault(address(redemptionVault)).hasAsset(asset_)) {
                revert InvalidAsset(asset_);
            }
            redeemableAssets.push(asset_);
        }
    }

    /**
     * @notice Transfers redemption assets for a given amount using a prioritized list of redeemable assets.
     * @dev Goes through the redeemableAssets in order and redeems as many shares as can for each asset.
     *      If there are shares left at the end, reverts.
     */
    function transferRedemptionAssets(address to, uint256 amount, bytes calldata /* data */ ) external override {
        (PreviewRedemption[] memory redemptions, uint256 sharesLeft) = this.previewTransferRedemptionAssets(amount);

        uint256 assetCount = redeemableAssets.length;
        for (uint256 i = 0; i < assetCount; ++i) {
            uint256 sharesToRedeem = redemptions[i].sharesRedeemed;
            address assetAddress = redemptions[i].asset;
            if (sharesToRedeem == 0) continue;

            // Redeem sharesToRedeem shares for assetAddress, sent to 'to'
            redemptionVault.redeemAsset(assetAddress, sharesToRedeem, to, address(this));
        }

        if (sharesLeft > 0) {
            revert NotEnoughLiquidityToFulfillRedemption();
        }
    }

    struct PreviewRedemption {
        address asset;
        uint256 sharesRedeemed;
        uint256 assetsRedeemable;
    }

    /**
     * @notice Previews how many shares of each redeemable asset would be redeemed for a given redemption amount,
     *         following the prioritized list of redeemableAssets. Does not modify state.
     * @param amount The total amount of underlying assets to redeem.
     * @return redemptions An array of PreviewRedemption structs for each asset in redeemableAssets order.
     */
    function previewTransferRedemptionAssets(uint256 amount)
        external
        view
        returns (PreviewRedemption[] memory redemptions, uint256 sharesLeft)
    {
        sharesLeft = IVault(address(redemptionVault)).convertToShares(amount);
        uint256 assetCount = redeemableAssets.length;
        redemptions = new PreviewRedemption[](assetCount);

        for (uint256 i = 0; i < assetCount; ++i) {
            if (sharesLeft > 0) {
                address assetAddress = redeemableAssets[i];
                uint256 maxRedeem = redemptionVault.maxRedeemAsset(assetAddress, address(this));

                uint256 sharesToRedeem = sharesLeft < maxRedeem ? sharesLeft : maxRedeem;
                uint256 assetsRedeemable = redemptionVault.previewRedeemAsset(assetAddress, sharesToRedeem);

                redemptions[i] = PreviewRedemption({
                    asset: assetAddress,
                    sharesRedeemed: sharesToRedeem,
                    assetsRedeemable: assetsRedeemable
                });

                sharesLeft -= sharesToRedeem;
            } else {
                redemptions[i] =
                    PreviewRedemption({ asset: redeemableAssets[i], sharesRedeemed: 0, assetsRedeemable: 0 });
            }
        }
    }

    /// @inheritdoc IRedemptionAssetsVault
    function withdrawRedemptionAssets(uint256 amount) external override { }

    /// @inheritdoc IRedemptionAssetsVault
    function redemptionRate() external view override returns (uint256) {
        // Consult the vault for conversion rate of 1 share to asset
        // Do not assume share decimals; fetch decimals from the vault.
        uint8 shareDecimals = IERC20Metadata(address(vault)).decimals();
        uint256 baseUnit = 10 ** uint256(shareDecimals);
        // (e.g. if 1 vault share = 1.05 assets, returns 1.05 * baseUnit for its decimals)
        return vault.convertToAssets(baseUnit);
    }

    /// @inheritdoc IRedemptionAssetsVault
    function availableRedemptionAssets() external view override returns (uint256) {
        // Returns the underlying asset balance available for withdrawal
        return IERC20Metadata(asset).balanceOf(address(redemptionVault));
    }
}
