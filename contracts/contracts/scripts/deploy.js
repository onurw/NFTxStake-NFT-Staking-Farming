const hre = require("hardhat");

async function main() {
  const [deployer, userA] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 1) Ödül tokenını deploy et (NXR)
  const Reward = await hre.ethers.getContractFactory("RewardToken");
  const reward = await Reward.deploy();
  await reward.waitForDeployment();
  console.log("RewardToken (NXR):", await reward.getAddress());

  // 2) Test için bir NFT koleksiyonu lazım.
  //    İstersen hazır bir koleksiyon adresi ver; burada OZ'nun basit bir mock'u yerine
  //    mevcut koleksiyonunu kullanacağını varsayalım (ENV ile).
  const NFT_ADDRESS = process.env.NFT_ADDRESS;
  if (!NFT_ADDRESS) {
    console.log("⚠️  Lütfen .env'de NFT_ADDRESS ayarla (mevcut bir ERC721 koleksiyon adresi).");
    console.log("Yine de kontratı deploy ediyorum ama stake için gerçek bir ERC721 gerekir.");
  }

  // 3) Staking kontratı
  const Stake = await hre.ethers.getContractFactory("NFTxStake");
  const stake = await Stake.deploy(NFT_ADDRESS || "0x0000000000000000000000000000000000000000", await reward.getAddress());
  await stake.waitForDeployment();
  console.log("NFTxStake:", await stake.getAddress());

  // 4) Örnek: kontrata 200,000 NXR fonla ve saniye başına 1 NXR dağıt
  const fundAmount = hre.ethers.parseEther("200000");
  await reward.transfer(await stake.getAddress(), fundAmount);
  await stake.setRewardRate(hre.ethers.parseEther("1"));
  console.log("Funded 200k NXR; rewardRate = 1 NXR/sec");
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
