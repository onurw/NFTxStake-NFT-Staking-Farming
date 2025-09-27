# NFTxStake — NFT Staking & Farming (weight destekli)

Bir ERC721 koleksiyonunu stake ederek **NXR** (ERC20) ödülü kazan. Her token için ağırlık atayarak (rarity/trait) ödül payını ayarlayabilirsin.

## Özellikler
- **Ağırlık**: `defaultWeight` (1e12=1.00x) veya tokenId -> `weight1e12`
- **Lineer dağıtım**: `rewardRate` (NXR/s)
- Çoklu `stake()/unstake()` ve `harvest()`
- `emergencyWithdrawAll()` (ödül sıfırlanır)
- `fundRewards()` ile kasaya token aktarımı

## Hızlı Başlangıç (yerel)
```bash
npm install
npm run build
npm run node
# yeni terminal
NFT_ADDRESS=0xSENIN_ERC721_ADRESIN npm run deploy:local
