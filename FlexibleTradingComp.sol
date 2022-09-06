// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";
import "bsc-library/contracts/IBEP20.sol";
import "bsc-library/contracts/SafeBEP20.sol";

import "./interfaces/IPancakeProfile.sol";
import "./BunnyMintingStation.sol";

/** @title FlexibleTradingComp.
@notice It is a contract for users to collect points
based on off-chain events
*/
contract FlexibleTradingComp is Ownable, ERC721Holder {
    using SafeBEP20 for IBEP20;

    IPancakeProfile public immutable pancakeProfile;
    BunnyMintingStation public immutable bunnyMintingStation;

    uint256 public constant numberTeams = 3;

    uint256 public competitionId;

    enum CompetitionStatus {
        Registration,
        Open,
        Close,
        Claiming,
        Over
    }

    mapping(uint256 => Competition) competitionData;

    struct Competition {
        mapping(address => UserStats) userTradingStats;
        mapping(uint256 => CompetitionRewards) _rewardCompetitions;
        IBEP20[] rewardTokens;
        IBEP20[] rewardMysteryBoxes; // 18 decimal tokens
        IERC721Enumerable[] rewardNFTCollections;
        CompetitionStatus currentStatus;
        uint8 bunnyId;
        uint256 winningTeamId; // set to 0 as default
        string bunnyTokenURI;
    }

    struct CompetitionRewards {
        uint256[5] userCampaignId; // campaignId for user increase
        mapping(uint256 => TokenRewards) tokenRewards; // tokens rewards per group
        uint256 tokenRewardsSize; // size of Token Rewards
        uint256[5] pointUsers; // number of points per user
    }

    struct CompetitionRewardsReview {
        uint256[5] userCampaignId; // campaignId for user increase
        TokenRewards[] tokenRewards; // tokens rewards per group
        uint256[5] pointUsers; // number of points per user
    }

    struct TokenRewards {
        uint256[5] rewards;
    }

    struct UserStats {
        uint256 rewardGroup; // 0 - 4 --> (Teal - 0, Purple - 1, Bronze - 2, Silver - 3, Gold - 4)
        uint256 teamId; // 1 - 3
        bool[] canClaimMysteryBoxes; // array of true or false
        bool hasRegistered; // true or false
        bool hasClaimed; // true or false
    }

    event NewCompetitionStatus(CompetitionStatus status, uint256 competitionId);
    event TeamRewardsUpdate(uint256 teamId, uint256 competitionId);
    event UserRegister(address userAddress, uint256 teamId, uint256 competitionId);
    event UserUpdateMultiple(address[] userAddresses, uint256 rewardGroup, uint256 competitionId);
    event UserUpdateMultipleMysteryBox(address[] userAddresses, bool[] canClaimMysteryBoxes, uint256 competitionId);
    event WinningTeam(uint256 teamId, uint256 competitionId);

    /**
     * @notice It initializes the contract.
     * @param _pancakeProfileAddress: PancakeProfile address
     * @param _bunnyStationAddress: BunnyMintingStation address
     * @param _tokenAddresses: the addresses of the reward tokens
     * @param _mysteryBoxAddress: the addresses of the mystery box token
     * @param _competitionId: competition uniq id
     */
    constructor(
        address _pancakeProfileAddress,
        address _bunnyStationAddress,
        address[] memory _tokenAddresses,
        address[] memory _mysteryBoxAddress,
        uint256 _competitionId
    ) public {
        pancakeProfile = IPancakeProfile(_pancakeProfileAddress);
        bunnyMintingStation = BunnyMintingStation(_bunnyStationAddress);

        Competition storage competition = competitionData[_competitionId];
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            competition.rewardTokens.push(IBEP20(_tokenAddresses[i]));
        }
        for (uint256 i = 0; i < _mysteryBoxAddress.length; i++) {
            competition.rewardMysteryBoxes.push(IBEP20(_mysteryBoxAddress[i]));
        }
        competition.currentStatus = CompetitionStatus.Registration;

        competitionId = _competitionId;
    }

    function startCompetition(uint256 _competitionId) external onlyOwner {
        require(competitionData[competitionId].currentStatus == CompetitionStatus.Over, "NOT_OVER");
        require(_competitionId - competitionId == 1, "NOT_ITERABLE_ID");

        delete competitionData[competitionId];

        Competition storage competition = competitionData[_competitionId];
        competition.currentStatus = CompetitionStatus.Registration;

        competitionId = _competitionId;

        emit NewCompetitionStatus(competition.currentStatus, competitionId);
    }

    /**
    * @notice setter for _tokenAddresses
    * @param _tokenAddresses - list of ERC20 addresses with 18 decimal
    */
    function setTokenAddress(address[] calldata _tokenAddresses) external onlyOwner {
        Competition storage competition = competitionData[competitionId];
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            competition.rewardTokens.push(IBEP20(_tokenAddresses[i]));
        }
    }

    /**
    * @notice setter for _mysteryBoxAddress
    * @param _mysteryBoxAddress - list of ERC20 addresses with 18 decimal
    */
    function setMysteryBoxAddress(address[] calldata _mysteryBoxAddress) external onlyOwner {
        Competition storage competition = competitionData[competitionId];
        for (uint256 i = 0; i < _mysteryBoxAddress.length; i++) {
            competition.rewardMysteryBoxes.push(IBEP20(_mysteryBoxAddress[i]));
        }
    }

    /**
    * @notice setter for _NFTCollectionAddress
    * @param _NFTCollectionAddress - list of IERC721Enumerable addresses
    */
    function setNFTCollectionAddress(address[] calldata _NFTCollectionAddress) external onlyOwner {
        Competition storage competition = competitionData[competitionId];
        for (uint256 i = 0; i < _NFTCollectionAddress.length; i++) {
            competition.rewardNFTCollections.push(IERC721Enumerable(_NFTCollectionAddress[i]));
        }
    }

    /**
     * @notice It allows users to claim reward after the end of trading competition.
     * @dev It is only available during claiming phase
     */
    function claimReward() external {
        address senderAddress = _msgSender();

        Competition storage competition = competitionData[competitionId];

        require(competition.userTradingStats[senderAddress].hasRegistered, "NOT_REGISTERED");
        require(!competition.userTradingStats[senderAddress].hasClaimed, "HAS_CLAIMED");
        require(competition.currentStatus == CompetitionStatus.Claiming, "NOT_IN_CLAIMING");

        uint256 registeredUserTeamId = competition.userTradingStats[senderAddress].teamId;
        bool isUserActive;
        uint256 userTeamId;
        (, , userTeamId, , , isUserActive) = pancakeProfile.getUserProfile(senderAddress);

        require(isUserActive, "NOT_ACTIVE");
        require(userTeamId == registeredUserTeamId, "USER_TEAM_HAS_CHANGED");

        competition.userTradingStats[senderAddress].hasClaimed = true;

        uint256 userRewardGroup = competition.userTradingStats[senderAddress].rewardGroup;
        bool[] memory canClaimMysteryBoxes = competition.userTradingStats[senderAddress].canClaimMysteryBoxes;

        CompetitionRewards storage userRewards = competition._rewardCompetitions[registeredUserTeamId];

        if (userRewardGroup > 0) {
            for (uint256 i = 0; i < competition.rewardTokens.length; i++) {
                competition.rewardTokens[i].safeTransfer(senderAddress, userRewards.tokenRewards[i].rewards[userRewardGroup]);
            }

            // TOP 100 users
            if (userRewardGroup > 1) {
                bunnyMintingStation.mintCollectible(senderAddress, competition.bunnyTokenURI, competition.bunnyId);
                for (uint256 i = 0; i < competition.rewardNFTCollections.length; i++) {
                    uint256 tokenId = competition.rewardNFTCollections[i].tokenOfOwnerByIndex(address(this), 0);
                    competition.rewardNFTCollections[i].safeTransferFrom(address(this), senderAddress, tokenId);
                }
            }
            for (uint256 i = 0; i < competition.rewardMysteryBoxes.length; i++) {
                if (canClaimMysteryBoxes.length > 0 && canClaimMysteryBoxes[i]) {
                    // send 1 mystery box token. 18 decimals
                    competition.rewardMysteryBoxes[i].safeTransfer(senderAddress, 1e18);
                }
            }
        }

        // User collects points
        pancakeProfile.increaseUserPoints(
            senderAddress,
            userRewards.pointUsers[userRewardGroup],
            userRewards.userCampaignId[userRewardGroup]
        );
    }

    /**
     * @notice It allows users to register for trading competition
     * @dev Only callable if the user has an active PancakeProfile.
     */
    function register() external {
        address senderAddress = _msgSender();

        Competition storage competition = competitionData[competitionId];
        // 1. Checks if user has registered
        require(!competition.userTradingStats[senderAddress].hasRegistered, "HAS_REGISTERED");

        // 2. Check whether it is joinable
        require(competition.currentStatus == CompetitionStatus.Registration, "NOT_IN_REGISTRATION");

        // 3. Check if active and records the teamId
        uint256 userTeamId;
        bool isUserActive;

        (, , userTeamId, , , isUserActive) = pancakeProfile.getUserProfile(senderAddress);

        require(isUserActive, "NOT_ACTIVE");

        // 4. Write in storage user stats for the registered user
        UserStats storage newUserStats = competition.userTradingStats[senderAddress];
        newUserStats.teamId = userTeamId;
        newUserStats.hasRegistered = true;

        emit UserRegister(senderAddress, userTeamId, competitionId);
    }

    /**
     * @notice It allows the owner to change the competition status
     * @dev Only callable by owner.
     * @param _status: CompetitionStatus (uint8)
     */
    function updateCompetitionStatus(CompetitionStatus _status) external onlyOwner {
        require(_status != CompetitionStatus.Registration, "IN_REGISTRATION");
        Competition storage competition = competitionData[competitionId];

        if (_status == CompetitionStatus.Open) {
            require(competition.currentStatus == CompetitionStatus.Registration, "NOT_IN_REGISTRATION");
        } else if (_status == CompetitionStatus.Close) {
            require(competition.currentStatus == CompetitionStatus.Open, "NOT_OPEN");
        } else if (_status == CompetitionStatus.Claiming) {
            require(competition.winningTeamId > 0, "WINNING_TEAM_NOT_SET");
            require(competition.bunnyId > 0, "BUNNY_ID_NOT_SET");
            require(bytes(competition.bunnyTokenURI).length > 0, "BUNNY_TOKEN_URI_IS_EMPTY");
            require(competition.rewardTokens.length > 0, "TOKEN_REWARD_ADDRESSES_IS_EMPTY");

            require(competition.currentStatus == CompetitionStatus.Close, "NOT_CLOSED");
        } else {
            require(competition.currentStatus == CompetitionStatus.Claiming, "NOT_CLAIMING");
        }

        competition.currentStatus = _status;

        emit NewCompetitionStatus(competition.currentStatus, competitionId);
    }

    /**
     * @notice It allows the owner to claim remainder
     * @dev Only callable by owner.
     * @param _amount: amount of tokens to withdraw (decimals = 18)
     * @param _cursor: cursor of token address to withdraw
     */
    function claimTokenRemainder(uint256 _amount, uint256 _cursor) external onlyOwner {
        Competition memory competition = competitionData[competitionId];

        require(competition.currentStatus == CompetitionStatus.Over, "NOT_OVER");
        require(competition.rewardTokens.length > _cursor, "CURSOR_TOO_HIGH");
        competition.rewardTokens[_cursor].safeTransfer(_msgSender(), _amount);
    }

    /**
     * @notice It allows the owner to claim the mystery box remainder
     * @dev Only callable by owner.
     * @param _amount: amount of mystery boxes to withdraw (decimals = 18)
     */
    function claimMysteryBoxRemainder(uint256 _amount, uint256 _cursor) external onlyOwner {
        Competition memory competition = competitionData[competitionId];

        require(competition.currentStatus == CompetitionStatus.Over, "NOT_OVER");
        require(competition.rewardMysteryBoxes.length > _cursor, "CURSOR_TOO_HIGH");
        competition.rewardMysteryBoxes[_cursor].safeTransfer(_msgSender(), _amount);
    }

    /**
     * @notice It allows the owner to claim the NFT remainder
     * @dev Only callable by owner.
     * @param tokenId: id of Avatar NFT
     */
    function claimNFTRemainder(uint256 tokenId, uint256 _cursor) external onlyOwner {
        Competition memory competition = competitionData[competitionId];

        require(competition.currentStatus == CompetitionStatus.Over, "NOT_OVER");
        require(competition.rewardNFTCollections.length > _cursor, "CURSOR_TOO_HIGH");
        competition.rewardNFTCollections[_cursor].safeTransferFrom(address(this), _msgSender(), tokenId);
    }

    /**
     * @notice It allows the owner to update team rewards
     * @dev Only callable by owner.
     * @param _teamId: the teamId
     * @param _userCampaignIds: campaignIds for each user group for teamId
     * @param _tokenRewards: token rewards for each user group for teamId
     * @param _pointRewards: point to collect for each user group for teamId
     */
    function updateTeamRewards(
        uint256 _teamId,
        uint256[5] calldata _userCampaignIds,
        uint256[5][] memory _tokenRewards,
        uint256[5] calldata _pointRewards
    ) external onlyOwner {
        Competition storage competition = competitionData[competitionId];

        require((_teamId > 0) && (_teamId <= numberTeams), "NOT_VALID_TEAM_ID");
        require(competition.currentStatus == CompetitionStatus.Close, "NOT_CLOSED");
        require(competition.rewardTokens.length == _tokenRewards.length, "NOT_SAME_REWARD_SIZE");

        CompetitionRewards storage rewardCompetitions = competition._rewardCompetitions[_teamId];
        rewardCompetitions.userCampaignId = _userCampaignIds;
        for (uint256 i = 0; i < _tokenRewards.length; i++) {
            rewardCompetitions.tokenRewards[i] = TokenRewards(_tokenRewards[i]);
        }
        rewardCompetitions.tokenRewardsSize = _tokenRewards.length;
        rewardCompetitions.pointUsers = _pointRewards;

        emit TeamRewardsUpdate(_teamId, competitionId);
    }

    /**
     * @notice It allows the owner to update user statuses
     * @dev Only callable by owner. Use with caution!
     * @param _addressesToUpdate: the array of addresses
     * @param _rewardGroup: the reward group
     */
    function updateUserStatusMultiple(address[] calldata _addressesToUpdate, uint256 _rewardGroup) external onlyOwner {
        Competition storage competition = competitionData[competitionId];

        require(competition.currentStatus == CompetitionStatus.Close, "NOT_CLOSED");
        require(_rewardGroup <= 4, "TOO_HIGH");
        for (uint256 i = 0; i < _addressesToUpdate.length; i++) {
            competition.userTradingStats[_addressesToUpdate[i]].rewardGroup = _rewardGroup;
        }

        emit UserUpdateMultiple(_addressesToUpdate, _rewardGroup, competitionId);
    }

    /**
     * @notice It allows the owner to update user statuses for MOBOX mystery box reward
     * @dev Only callable by owner. Use with caution!
     * @param _addressesToUpdate: the array of addresses
     * @param _canClaimMysteryBoxes: flag for mystery box
     */
    function updateUserStatusMysteryBox(address[] calldata _addressesToUpdate, bool[] memory _canClaimMysteryBoxes)
    external
    onlyOwner
    {
        Competition storage competition = competitionData[competitionId];
        require(competition.currentStatus == CompetitionStatus.Close, "NOT_CLOSED");
        require(competition.rewardMysteryBoxes.length == _canClaimMysteryBoxes.length, "NOT_SAME_REWARD_SIZE");
        for (uint256 i = 0; i < _addressesToUpdate.length; i++) {
            competition.userTradingStats[_addressesToUpdate[i]].canClaimMysteryBoxes = _canClaimMysteryBoxes;
        }

        emit UserUpdateMultipleMysteryBox(_addressesToUpdate, _canClaimMysteryBoxes, competitionId);
    }

    /**
     * @notice It allows the owner to set the winning teamId (to collect NFT)
     * @dev Only callable by owner.
     * @param _winningTeamId: the winning teamId
     * @param _tokenURI: the tokenURI
     * @param _bunnyId: the bunnyId for winners (e.g. 15)
     */
    function updateWinningTeamAndTokenURIAndBunnyId(
        uint256 _winningTeamId,
        string calldata _tokenURI,
        uint8 _bunnyId
    ) external onlyOwner {
        Competition storage competition = competitionData[competitionId];

        require(competition.currentStatus == CompetitionStatus.Close, "NOT_CLOSED");
        require((_winningTeamId > 0) && (_winningTeamId <= numberTeams), "NOT_VALID_TEAM_ID");
        require(_bunnyId > 0, "BUNNY_ID_NOT_SET");
        require(bytes(_tokenURI).length > 0, "BUNNY_TOKEN_URI_IS_EMPTY");

        competition.winningTeamId = _winningTeamId;
        competition.bunnyTokenURI = _tokenURI;
        competition.bunnyId = _bunnyId;
        emit WinningTeam(_winningTeamId, competitionId);
    }

    /**
     * @notice It checks the claim information
     * @dev It does not check if user has a profile since registration required a profile.
     * @param _userAddress: the user address
     * @return hasRegistered: has the user registered
     * @return isActive: is the user active
     * @return hasUserClaimed: whether user has claimed
     * @return userRewardGroup: the final reward group for each user (i.e. tier)
     * @return userTokenRewards: tokens from each reward collection to claim/claimed
     * @return userPointReward: the number of points to claim/claimed
     * @return canClaimMysteryBoxes: whether the user gets/got a mystery box. arrays order based on rewardMysteryBoxes
     * @return canClaimNFT: whether the user gets/got a NFT
     */
    function claimInformation(address _userAddress)
    external
    view
    returns (
        bool,
        bool,
        bool,
        uint256,
        uint256[] memory,
        uint256,
        bool[] memory,
        bool
    )
    {
        bool isUserActive;
        (,,,,, isUserActive) = pancakeProfile.getUserProfile(_userAddress);
        UserStats memory userStats = competitionData[competitionId].userTradingStats[_userAddress];
        bool hasUserRegistered = userStats.hasRegistered;
        uint256[] memory tokenRewards;
        bool[] memory canClaimMysteryBoxes;

        if ((competitionData[competitionId].currentStatus != CompetitionStatus.Claiming)
            && (competitionData[competitionId].currentStatus != CompetitionStatus.Over)) {
            return (hasUserRegistered, isUserActive, false, 0, tokenRewards, 0, canClaimMysteryBoxes, false);
        } else if (!hasUserRegistered || !isUserActive) {
            return (hasUserRegistered, isUserActive, false, 0, tokenRewards, 0, canClaimMysteryBoxes, false);
        } else {
            uint256 userRewardGroup = userStats.rewardGroup;
            canClaimMysteryBoxes = userStats.canClaimMysteryBoxes;

            bool canClaimNFT;
            if (userRewardGroup > 1) {
                canClaimNFT = true;
            }

            tokenRewards = new uint256[](competitionData[competitionId]._rewardCompetitions[userStats.teamId].tokenRewardsSize);
            for (uint256 i = 0; i < competitionData[competitionId]._rewardCompetitions[userStats.teamId].tokenRewardsSize; i++) {
                tokenRewards[i] = competitionData[competitionId]._rewardCompetitions[userStats.teamId].tokenRewards[i].rewards[userRewardGroup];
            }


            return (
            hasUserRegistered,
            isUserActive,
            userStats.hasClaimed,
            userRewardGroup,
            tokenRewards,
            competitionData[competitionId]._rewardCompetitions[userStats.teamId].pointUsers[userRewardGroup],
            canClaimMysteryBoxes,
            canClaimNFT
            );
        }
    }

    /**
     * @notice It checks the reward groups for each team
     */
    function viewRewardTeams() external view returns (CompetitionRewardsReview[] memory) {
        CompetitionRewardsReview[] memory list = new CompetitionRewardsReview[](numberTeams);
        for (uint256 i = 0; i < numberTeams; i++) {
            CompetitionRewards storage a = competitionData[competitionId]._rewardCompetitions[i + 1];
            list[i].userCampaignId = a.userCampaignId;
            list[i].pointUsers = a.pointUsers;

            for (uint256 j = 0; j < a.tokenRewardsSize; j++) {
                list[i].tokenRewards[j] = a.tokenRewards[j];
            }
        }
        return list;
    }
}