// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title NFTxStake
 * @notice Belirli bir ERC721 koleksiyonu stake ederek ERC20 ödül kazanma.
 * - Ağırlık (weight) desteği: tokenId -> weight (1e12 ölçekli), yoksa defaultWeight kullanılır.
 * - accRewardPerWeight muhasebesi ile adil dağıtım.
 * - Çoklu stake/unstake, harvest, emergencyWithdraw.
 *
 * Üretim notu: timelock/governor, blacklist, per-user/tx limitler, reentrancy/pausable (var), audit önerilir.
 */
contract NFTxStake is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // --- Immutable config ---
    IERC20  public immutable rewardToken;
    IERC721 public immutable nft;

    // --- Rewards accounting ---
    uint256 public rewardRate;               // saniye başına dağıtılan NXR
    uint256 public lastUpdate;
    uint256 public accRewardPerWeight;       // 1e12 ölçek
    uint256 public totalWeight;              // havuz toplam ağırlık (1e12 ölçekli)

    // --- Weights ---
    uint256 public defaultWeight = 1_000_000_000_000; // 1e12 = 1.00x
    mapping(uint256 => uint256) public tokenWeight;   // tokenId -> weight (1e12 ölçek). 0 ise defaultWeight.

    // --- Ownership / staking state ---
    mapping(uint256 => address) public tokenOwner;       // tokenId -> staker
    mapping(uint256 => uint64)  public stakedAt;         // tokenId -> since
    mapping(address => uint256[]) private _userTokens;   // staker -> token list
    mapping(uint256 => uint256)  private _idxInOwner;    // tokenId -> index in owner's array

    // --- Per-user reward state ---
    mapping(address => uint256) public userWeight;       // toplam ağırlık (1e12 ölçek)
    mapping(address => uint256) public rewardDebt;       // userWeight * accRewardPerWeight / 1e12
    mapping(address => uint256) public pending;          // birikmiş ama çekilmemiş

    // --- Events ---
    event Deposited(address indexed user, uint256[] tokenIds, uint256 addedWeight);
    event Withdrawn(address indexed user, uint256[] tokenIds, uint256 removedWeight);
    event Harvest(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amountNfts);
    event RewardRateUpdated(uint256 newRate);
    event WeightSet(uint256 indexed tokenId, uint256 weight1e12);
    event DefaultWeightSet(uint256 newWeight1e12);
    event Funded(uint256 amount);

    constructor(IERC721 _nft, IERC20 _reward) {
        nft = _nft;
        rewardToken = _reward;
        lastUpdate = block.timestamp;
    }

    // -------- Owner controls --------

    function setRewardRate(uint256 newRate) external onlyOwner {
        _updatePool();
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }

    function fundRewards(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount);
    }

    function setDefaultWeight(uint256 w1e12) external onlyOwner {
        require(w1e12 > 0, "w=0");
        defaultWeight = w1e12;
        emit DefaultWeightSet(w1e12);
    }

    function setTokenWeights(uint256[] calldata ids, uint256[] calldata weights1e12) external onlyOwner {
        require(ids.length == weights1e12.length && ids.length > 0, "bad len");
        for (uint256 i = 0; i < ids.length; i++) {
            tokenWeight[ids[i]] = weights1e12[i];
            emit WeightSet(ids[i], weights1e12[i]);
        }
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------- User actions --------

    function stake(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "empty");
        _updatePool();

        // önce ödülü güncelle
        _harvestIntoPending(msg.sender);

        uint256 addW;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            require(tokenOwner[id] == address(0), "already staked");

            // transfer NFT
            nft.safeTransferFrom(msg.sender, address(this), id);

            // kayıt
            tokenOwner[id] = msg.sender;
            stakedAt[id] = uint64(block.timestamp);

            // owner array’e ekle
            _idxInOwner[id] = _userTokens[msg.sender].length;
            _userTokens[msg.sender].push(id);

            // weight
            uint256 w = tokenWeight[id];
            addW += (w == 0 ? defaultWeight : w);
        }

        userWeight[msg.sender] += addW;
        totalWeight += addW;

        // yeni rewardDebt
        rewardDebt[msg.sender] = userWeight[msg.sender] * accRewardPerWeight / 1e12;

        emit Deposited(msg.sender, tokenIds, addW);
    }

    function unstake(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "empty");
        _updatePool();
        _harvestIntoPending(msg.sender);

        uint256 subW;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            require(tokenOwner[id] == msg.sender, "not owner");

            // weight düş
            uint256 w = tokenWeight[id];
            subW += (w == 0 ? defaultWeight : w);

            // owner array’den çıkar (swap&pop)
            uint256 lastIdx = _userTokens[msg.sender].length - 1;
            uint256 myIdx  = _idxInOwner[id];
            if (myIdx != lastIdx) {
                uint256 lastToken = _userTokens[msg.sender][lastIdx];
                _userTokens[msg.sender][myIdx] = lastToken;
                _idxInOwner[lastToken] = myIdx;
            }
            _userTokens[msg.sender].pop();
            _idxInOwner[id] = 0;

            // sahiplik temizle & transfer NFT
            tokenOwner[id] = address(0);
            stakedAt[id] = 0;
            nft.safeTransferFrom(address(this), msg.sender, id);
        }

        userWeight[msg.sender] -= subW;
        totalWeight -= subW;

        rewardDebt[msg.sender] = userWeight[msg.sender] * accRewardPerWeight / 1e12;

        emit Withdrawn(msg.sender, tokenIds, subW);
    }

    function harvest() external nonReentrant whenNotPaused {
        _updatePool();
        _harvestIntoPending(msg.sender);

        uint256 amt = pending[msg.sender];
        require(amt > 0, "nothing");
        pending[msg.sender] = 0;
        rewardDebt[msg.sender] = userWeight[msg.sender] * accRewardPerWeight / 1e12;

        rewardToken.safeTransfer(msg.sender, amt);
        emit Harvest(msg.sender, amt);
    }

    /**
     * @dev Kilide bakmadan tüm NFT’leri geri verir, tüm birikmiş ödülleri sıfırlar.
     * Üretimde ceza/fee uygulanabilir.
     */
    function emergencyWithdrawAll() external nonReentrant {
        _updatePool();
        uint256 len = _userTokens[msg.sender].length;
        require(len > 0, "no nfts");

        // tüm NFT’leri iade
        for (uint256 i = 0; i < len; i++) {
            uint256 id = _userTokens[msg.sender][i];
            tokenOwner[id] = address(0);
            stakedAt[id] = 0;
            nft.safeTransferFrom(address(this), msg.sender, id);
        }
        delete _userTokens[msg.sender];

        // ağırlık/ödül state sıfırla
        totalWeight -= userWeight[msg.sender];
        userWeight[msg.sender] = 0;
        rewardDebt[msg.sender] = 0;
        pending[msg.sender] = 0;

        emit EmergencyWithdraw(msg.sender, len);
    }

    // -------- Views --------

    function userTokens(address user) external view returns (uint256[] memory) {
        return _userTokens[user];
    }

    function pendingRewards(address user) external view returns (uint256) {
        uint256 _acc = accRewardPerWeight;
        if (block.timestamp > lastUpdate && totalWeight > 0 && rewardRate > 0) {
            uint256 dt = block.timestamp - lastUpdate;
            uint256 add = dt * rewardRate * 1e12 / totalWeight;
            _acc += add;
        }
        return pending[user] + (userWeight[user] * _acc / 1e12) - rewardDebt[user];
    }

    // -------- Internal accounting --------

    function _updatePool() internal {
        if (block.timestamp <= lastUpdate) return;
        if (totalWeight == 0 || rewardRate == 0) {
            lastUpdate = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - lastUpdate;
        uint256 add = dt * rewardRate * 1e12 / totalWeight;
        accRewardPerWeight += add;
        lastUpdate = block.timestamp;
    }

    function _harvestIntoPending(address user) internal {
        if (userWeight[user] == 0) { rewardDebt[user] = 0; return; }
        uint256 accrued = userWeight[user] * accRewardPerWeight / 1e12;
        uint256 delta = accrued - rewardDebt[user];
        if (delta > 0) {
            pending[user] += delta;
        }
        rewardDebt[user] = userWeight[user] * accRewardPerWeight / 1e12;
    }

    // -------- Hooks --------

    // Bu kontrat doğrudan safeTransferFrom ile NFT alıyor; onERC721Received gerekmez.
    // Yine de yanlışlıkla gönderimleri engellemek istersen Pausable'ı kontrol ederek revert edebilirsin.
}
