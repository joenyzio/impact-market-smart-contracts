// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/CommunityAdminStorageV1Old.sol";

/**
 * @notice Welcome to CommunityAdmin, the main contract. This is an
 * administrative (for now) contract where the admins have control
 * over the list of communities. Being only able to add and
 * remove communities
 */
contract CommunityAdminImplementationOld is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    CommunityAdminStorageV1Old
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant DEFAULT_AMOUNT = 5e16;
    uint256 private constant TREASURY_SAFETY_FACTOR = 10;

    /**
     * @notice Triggered when a community has been added
     *
     * @param communityAddress  Address of the community that has been added
     * @param managers          Addresses of the initial managers
     * @param claimAmount       Value of the claimAmount
     * @param maxClaim          Value of the maxClaim
     * @param decreaseStep      Value of the decreaseStep
     * @param baseInterval      Value of the baseInterval
     * @param incrementInterval Value of the incrementInterval
     * @param minTranche        Value of the minTranche
     * @param maxTranche        Value of the maxTranche
     *
     * For further information regarding each parameter, see
     * *Community* smart contract initialize method.
     */
    event CommunityAdded(
        address indexed communityAddress,
        address[] managers,
        uint256 claimAmount,
        uint256 maxClaim,
        uint256 decreaseStep,
        uint256 baseInterval,
        uint256 incrementInterval,
        uint256 minTranche,
        uint256 maxTranche
    );

    /**
     * @notice Triggered when a community has been removed
     *
     * @param communityAddress  Address of the community that has been removed
     */
    event CommunityRemoved(address indexed communityAddress);

    /**
     * @notice Triggered when a community has been migrated
     *
     * @param managers                 Addresses of the new community's initial managers
     * @param communityAddress         New community address
     * @param previousCommunityAddress Old community address
     */
    event CommunityMigrated(
        address[] managers,
        address indexed communityAddress,
        address indexed previousCommunityAddress
    );

    /**
     * @notice Triggered when the treasury address has been updated
     *
     * @param oldTreasury             Old treasury address
     * @param newTreasury             New treasury address
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Triggered when the communityImplementation address has been updated
     *
     * @param oldCommunityImplementation    Old communityImplementation address
     * @param newCommunityImplementation    New communityImplementation address
     */
    event CommunityImplementationUpdated(
        address indexed oldCommunityImplementation,
        address indexed newCommunityImplementation
    );

    /**
     * @notice Triggered when a community has been funded
     *
     * @param community           Address of the community
     * @param amount              Amount of the funding
     */
    event CommunityFunded(address indexed community, uint256 amount);

    /**
     * @notice Triggered when an amount of an ERC20 has been transferred from this contract to an address
     *
     * @param token               ERC20 token address
     * @param to                  Address of the receiver
     * @param amount              Amount of the transaction
     */
    event TransferERC20(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Enforces sender to be a valid community
     */
    modifier onlyCommunities() {
        require(communities[msg.sender] == CommunityState.Valid, "CommunityAdmin: NOT_COMMUNITY");
        _;
    }

    /**
     * @notice Used to initialize a new CommunityAdmin contract
     *
     * @param _communityImplementation    Address of the Community implementation
     *                              used for deploying new communities
     * @param _cUSD                 Address of the cUSD token
     */
    function initialize(ICommunityOld _communityImplementation, IERC20 _cUSD) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        communityImplementation = _communityImplementation;
        cUSD = _cUSD;

        communityProxyAdmin = new ProxyAdmin();
    }

    /**
     * @notice Returns the current implementation version
     */
    function getVersion() external pure override returns (uint256) {
        return 1;
    }

    /**
     * @notice Returns the address of a community from communityList
     *
     * @param _index index of the community
     * @return address of the community
     */
    function communityListAt(uint256 _index) external view override returns (address) {
        return communityList.at(_index);
    }

    /**
     * @notice Returns the number of communities
     *
     * @return uint256 number of communities
     */
    function communityListLength() external view override returns (uint256) {
        return communityList.length();
    }

    /**
     * @notice Updates the address of the treasury
     *
     * @param _newTreasury address of the new treasury contract
     */
    function updateTreasury(ITreasury _newTreasury) external override onlyOwner {
        address oldTreasuryAddress = address(treasury);
        treasury = _newTreasury;

        emit TreasuryUpdated(oldTreasuryAddress, address(_newTreasury));
    }

    /**
     * @notice Updates the address of the the communityImplementation
     *
     * @param _newCommunityImplementation address of the new communityImplementation contract
     */
    function updateCommunityImplementation(ICommunityOld _newCommunityImplementation) external override onlyOwner {
        address _oldCommunityImplementationAddress = address(communityImplementation);
        communityImplementation = _newCommunityImplementation;

        emit CommunityImplementationUpdated(_oldCommunityImplementationAddress, address(_newCommunityImplementation));
    }

    /**
     * @notice Adds a new community
     *
     * @param _managers addresses of the community managers
     * @param _claimAmount base amount to be claim by the beneficiary
     * @param _maxClaim limit that a beneficiary can claim at in total
     * @param _decreaseStep value decreased from maxClaim for every beneficiary added
     * @param _baseInterval base interval to start claiming
     * @param _incrementInterval increment interval used in each claim
     * @param _minTranche minimum amount that the community will receive when requesting funds
     * @param _maxTranche maximum amount that the community will receive when requesting funds
     */
    function addCommunity(
        address[] memory _managers,
        uint256 _claimAmount,
        uint256 _maxClaim,
        uint256 _decreaseStep,
        uint256 _baseInterval,
        uint256 _incrementInterval,
        uint256 _minTranche,
        uint256 _maxTranche
    ) external override onlyOwner {
        require(
            _managers.length > 0,
            "CommunityAdmin::addCommunity: Community should have at least one manager"
        );
        address _communityAddress = deployCommunity(
            _managers,
            _claimAmount,
            _maxClaim,
            _decreaseStep,
            _baseInterval,
            _incrementInterval,
            _minTranche,
            _maxTranche,
            ICommunityOld(address(0))
        );
        require(_communityAddress != address(0), "CommunityAdmin::addCommunity: NOT_VALID");
        communities[_communityAddress] = CommunityState.Valid;
        communityList.add(_communityAddress);

        emit CommunityAdded(
            _communityAddress,
            _managers,
            _claimAmount,
            _maxClaim,
            _decreaseStep,
            _baseInterval,
            _incrementInterval,
            _minTranche,
            _maxTranche
        );

        transferToCommunity(ICommunityOld(_communityAddress), _minTranche);
        treasury.transfer(cUSD, address(_managers[0]), DEFAULT_AMOUNT);
    }

    /**
     * @notice Migrates a community by deploying a new contract.
     *
     * @param _managers address of the community managers
     * @param _previousCommunity address of the community to be migrated
     */
    function migrateCommunity(address[] memory _managers, ICommunityOld _previousCommunity)
        external
        override
        onlyOwner
        nonReentrant
    {
        require(
            communities[address(_previousCommunity)] != CommunityState.Migrated,
            "CommunityAdmin::migrateCommunity: this community has been migrated"
        );

        communities[address(_previousCommunity)] = CommunityState.Migrated;

        bool _isCommunityNew = isCommunityNewType(_previousCommunity);

        address newCommunityAddress;
        if (_isCommunityNew) {
            newCommunityAddress = deployCommunity(
                _managers,
                _previousCommunity.claimAmount(),
                _previousCommunity.getInitialMaxClaim(),
                _previousCommunity.decreaseStep(),
                _previousCommunity.baseInterval(),
                _previousCommunity.incrementInterval(),
                _previousCommunity.minTranche(),
                _previousCommunity.maxTranche(),
                _previousCommunity
            );
        } else {
            newCommunityAddress = deployCommunity(
                _managers,
                _previousCommunity.claimAmount(),
                _previousCommunity.maxClaim(),
                1e16,
                (_previousCommunity.baseInterval() / 5),
                (_previousCommunity.incrementInterval() / 5),
                1e16,
                5e18,
                _previousCommunity
            );
        }

        require(newCommunityAddress != address(0), "CommunityAdmin::migrateCommunity: NOT_VALID");

        if (_isCommunityNew) {
            uint256 balance = cUSD.balanceOf(address(_previousCommunity));
            _previousCommunity.transfer(cUSD, newCommunityAddress, balance);
        }

        communities[newCommunityAddress] = CommunityState.Valid;
        communityList.add(newCommunityAddress);

        emit CommunityMigrated(_managers, newCommunityAddress, address(_previousCommunity));
    }

    /**
     * @notice Adds a new manager to a community
     *
     * @param _community address of the community
     * @param _account address to be added as community manager
     */
    function addManagerToCommunity(ICommunityOld _community, address _account)
        external
        override
        onlyOwner
    {
        _community.addManager(_account);
    }

    /**
     * @notice Removes an existing community. All community funds are transferred to the treasury
     *
     * @param _community address of the community
     */
    function removeCommunity(ICommunityOld _community) external override onlyOwner nonReentrant {
        require(
            communities[address(_community)] == CommunityState.Valid,
            "CommunityAdmin::removeCommunity: this isn't a valid community"
        );
        communities[address(_community)] = CommunityState.Removed;

        _community.transfer(cUSD, address(treasury), cUSD.balanceOf(address(_community)));
        emit CommunityRemoved(address(_community));
    }

    /**
     * @dev Funds an existing community if it hasn't enough funds
     */
    function fundCommunity() external override onlyCommunities {
        ICommunityOld _community = ICommunityOld(msg.sender);
        uint256 _balance = cUSD.balanceOf(msg.sender);
        require(
            _balance < _community.minTranche(),
            "CommunityAdmin::fundCommunity: this community has enough funds"
        );
        require(
            block.number > _community.lastFundRequest() + _community.baseInterval(),
            "CommunityAdmin::fundCommunity: this community is not allowed to request yet"
        );

        uint256 _trancheAmount = calculateCommunityTrancheAmount(ICommunityOld(msg.sender));

        if (_trancheAmount > _balance) {
            uint256 _amount = _trancheAmount - _balance;
            uint256 _treasurySafetyBalance = cUSD.balanceOf(address(treasury)) /
                TREASURY_SAFETY_FACTOR;
            require(
                _amount <= _treasurySafetyBalance,
                "CommunityAdmin::fundCommunity: Not enough funds"
            );
            transferToCommunity(_community, _amount);
        }
    }

    /**
     * @notice Transfers an amount of an ERC20 from this contract to an address
     *
     * @param _token address of the ERC20 token
     * @param _to address of the receiver
     * @param _amount amount of the transaction
     */
    function transfer(
        IERC20 _token,
        address _to,
        uint256 _amount
    ) external override onlyOwner nonReentrant {
        _token.safeTransfer(_to, _amount);

        emit TransferERC20(address(_token), _to, _amount);
    }

    /**
     * @notice Transfers an amount of an ERC20 from  community to an address
     *
     * @param _community address of the community
     * @param _token address of the ERC20 token
     * @param _to address of the receiver
     * @param _amount amount of the transaction
     */
    function transferFromCommunity(
        ICommunityOld _community,
        IERC20 _token,
        address _to,
        uint256 _amount
    ) external override onlyOwner nonReentrant {
        _community.transfer(_token, _to, _amount);
    }

    /** @notice Updates the beneficiary params of a community
     *
     * @param _community address of the community
     * @param _claimAmount  base amount to be claim by the beneficiary
     * @param _maxClaim limit that a beneficiary can claim  in total
     * @param _decreaseStep value decreased from maxClaim each time a is beneficiary added
     * @param _baseInterval base interval to start claiming
     * @param _incrementInterval increment interval used in each claim
     */
    function updateBeneficiaryParams(
        ICommunityOld _community,
        uint256 _claimAmount,
        uint256 _maxClaim,
        uint256 _decreaseStep,
        uint256 _baseInterval,
        uint256 _incrementInterval
    ) external override onlyOwner {
        _community.updateBeneficiaryParams(
            _claimAmount,
            _maxClaim,
            _decreaseStep,
            _baseInterval,
            _incrementInterval
        );
    }

    /** @notice Updates params of a community
     *
     * @param _community address of the community
     * @param _minTranche minimum amount that the community will receive when requesting funds
     * @param _maxTranche maximum amount that the community will receive when requesting funds
     */
    function updateCommunityParams(
        ICommunityOld _community,
        uint256 _minTranche,
        uint256 _maxTranche
    ) external override onlyOwner {
        _community.updateCommunityParams(_minTranche, _maxTranche);
    }

    /**
     * @notice Updates proxy implementation address of a community
     *
     * @param _CommunityMiddleProxy address of the community
     * @param _newCommunityImplementation address of new implementation contract
     */
    function updateProxyImplementation(address _CommunityMiddleProxy, address _newCommunityImplementation)
        external
        override
        onlyOwner
    {
        communityProxyAdmin.upgrade(
            TransparentUpgradeableProxy(payable(_CommunityMiddleProxy)),
            _newCommunityImplementation
        );
    }

    /**
     * @dev Transfers cUSDs from the treasury to a community
     *
     * @param _community address of the community
     * @param _amount amount of the transaction
     */
    function transferToCommunity(ICommunityOld _community, uint256 _amount) internal nonReentrant {
        treasury.transfer(cUSD, address(_community), _amount);
        _community.addTreasuryFunds(_amount);

        emit CommunityFunded(address(_community), _amount);
    }

    /**
     * @dev Internal implementation of deploying a new community
     *
     * @param _managers addresses of the community managers
     * @param _claimAmount base amount to be claim by the beneficiary
     * @param _maxClaim limit that a beneficiary can claim at in total
     * @param _decreaseStep value decreased from maxClaim for every beneficiary added
     * @param _baseInterval base interval to start claiming
     * @param _incrementInterval increment interval used in each claim
     * @param _minTranche minimum amount that the community will receive when requesting funds
     * @param _maxTranche maximum amount that the community will receive when requesting funds
     * @param _previousCommunity address of the previous community. Used for migrating communities
     */
    function deployCommunity(
        address[] memory _managers,
        uint256 _claimAmount,
        uint256 _maxClaim,
        uint256 _decreaseStep,
        uint256 _baseInterval,
        uint256 _incrementInterval,
        uint256 _minTranche,
        uint256 _maxTranche,
        ICommunityOld _previousCommunity
    ) internal returns (address) {
        TransparentUpgradeableProxy _community = new TransparentUpgradeableProxy(
            address(communityImplementation),
            address(communityProxyAdmin),
            abi.encodeWithSignature(
                "initialize(address[],uint256,uint256,uint256,uint256,uint256,uint256,uint256,address)",
                _managers,
                _claimAmount,
                _maxClaim,
                _decreaseStep,
                _baseInterval,
                _incrementInterval,
                _minTranche,
                _maxTranche,
                address(_previousCommunity)
            )
        );

        return address(_community);
    }

    /** @dev Calculates the tranche amount of a community.
     *        Enforces the tranche amount to be between community minTranche and maxTranche
     * @param _community address of the community
     * @return uint256 the value of the tranche amount
     */
    function calculateCommunityTrancheAmount(ICommunityOld _community)
        internal
        view
        returns (uint256)
    {
        uint256 _validBeneficiaries = _community.validBeneficiaryCount();
        uint256 _claimAmount = _community.claimAmount();
        uint256 _treasuryFunds = _community.treasuryFunds();
        uint256 _privateFunds = _community.privateFunds();
        uint256 _minTranche = _community.minTranche();
        uint256 _maxTranche = _community.maxTranche();

        // `treasuryFunds` can't be zero.
        // Otherwise, migrated communities will have zero.
        _treasuryFunds = _treasuryFunds > 0 ? _treasuryFunds : 1e18;

        uint256 _trancheAmount = (_validBeneficiaries *
            _claimAmount *
            (_treasuryFunds + _privateFunds)) / _treasuryFunds;

        if (_trancheAmount < _minTranche) {
            _trancheAmount = _minTranche;
        } else if (_trancheAmount > _maxTranche) {
            _trancheAmount = _maxTranche;
        }

        return _trancheAmount;
    }

    /**
     * @notice Checks if a community is deployed with the new type of smart contract
     *
     * @param _community address of the community
     * @return bool true if the community is deployed with the new type of smart contract
     */
    function isCommunityNewType(ICommunityOld _community) internal pure returns (bool) {
        return _community.impactMarketAddress() == address(0);
    }
}
