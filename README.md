# StakingV1 — Fixed APY Single-Asset Staking

Production-ready staking contract with fixed APY rewards.
Users stake tokens and earn rewards at a configurable
annual percentage yield.

## Features:
- Fixed APY staking (default 120%, max 500%)
- 7-day lock period before unstake
- Auto-claim on additional stake
- Reward balance tracking (totalStaked excluded)
- Emergency withdraw for owner
- 55 tests passing including fuzz tests
- Deployed and verified on Sepolia
- Reward pool funded with 100,000 MET

## Deployed Contract

| Network | Address | Etherscan |
|---------|---------|-----------|
| Sepolia | `0xYourContractAddress` | [View](https://sepolia.etherscan.io/address/0xYourAddress) |

## How It Works
```
User approves staking contract
         ↓
User calls stake(amount)
         ↓
Tokens locked for 7-day period
         ↓
Rewards accrue every second
reward = amount × APY × timeStaked ÷ (10000 × 365 days)
         ↓
User claims reward or waits to unstake
         ↓
After lock period: unstake returns tokens + auto-claimed reward
```


## Reward Example

| Stake Amount | APY   | Duration | Reward     |
|-------------|-------|----------|------------|
| 1,000 MET   | 120%  | 1 day    | ~3.29 MET  |
| 1,000 MET   | 120%  | 30 days  | ~98.6 MET  |
| 1,000 MET   | 120%  | 1 year   | 1,200 MET  |
| 10,000 MET  | 120%  | 30 days  | ~986 MET   |

## Contract Parameters

| Parameter | Value |
|-----------|-------|
| Lock Period | 7 days |
| Default APY | 120% (12,000 bps) |
| Max APY | 500% (50,000 bps) |
| Minimum Stake | 1 token |
| Reward Model | Fixed APY |
| Token | MET (MyToken) |

## How to Stake

```bash
# 1. Approve staking contract
cast send $TOKEN_ADDRESS \
  "approve(address,uint256)" \
  $STAKING_ADDRESS \
  1000000000000000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# 2. Stake tokens
cast send $STAKING_ADDRESS \
  "stake(uint256)" \
  1000000000000000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# 3. Check your staking info
cast call $STAKING_ADDRESS \
  "getStakerInfo(address)" \
  $YOUR_ADDRESS \
  --rpc-url $RPC_URL
```

## Security Considerations

**ReentrancyGuard**
All state-changing functions with ETH/token transfers
are protected with nonReentrant modifier.

**Checks-Effects-Interactions**
State updated before all external token transfers
throughout the contract.

**Available Reward Check**
Contract verifies sufficient reward balance before
every claim — users can always unstake even if
reward pool is empty.

**Same Token Accounting**
availableRewardBalance() = totalBalance - totalStaked
Prevents staked tokens from being counted as reward.

**Emergency Withdraw**
Owner can withdraw all tokens in case of critical bug.
Emits event for full transparency.

## Test Coverage

```bash
forge test --gas-report
```

55 tests — all passing including fuzz tests.

## License

MIT



# StakingV2 — Dynamic Reward Staking Contract

A production-grade ERC20 staking contract with dynamic reward rates, built with Solidity and Foundry.

Deployed on Sepolia Testnet:
- **StakingV2**: `0xYourContractAddress`
- **Stake Token**: `0xYourStakeTokenAddress`
- **Reward Token**: `0xYourRewardTokenAddress`

[View on Etherscan](https://sepolia.etherscan.io/address/0xYourContractAddress)

---

## Overview

StakingV2 implements the **Synthetix reward distribution pattern** — the industry standard for DeFi staking protocols. Users stake ERC20 tokens and earn rewards continuously per second, with reward rates adjustable by the contract owner.

### How It Works

1. Owner funds the contract with reward tokens and sets a reward rate (tokens/second)
2. Users approve and stake their tokens
3. Rewards accumulate continuously based on each user's share of the total staked pool
4. Users can claim rewards at any time without unstaking
5. Emergency withdraw available (forfeits pending rewards)

### Reward Formula

```
rewardPerToken = rewardPerTokenStored + 
  (rewardRate × timeElapsed × 1e18) / totalSupply

userReward = (userBalance × (rewardPerToken - userRewardPerTokenPaid)) / 1e18
           + rewards[user]
```

---

## Features

- ERC20 token staking with dynamic reward rates
- Synthetix-pattern reward distribution (per-second, pro-rata)
- Owner-adjustable reward rate without disrupting existing stakers
- Emergency withdraw (no rewards, full principal)
- Reentrancy protection via OpenZeppelin ReentrancyGuard
- Comprehensive test suite (unit + fuzz tests)

---

## Tech Stack

- **Solidity** ^0.8.20
- **Foundry** (build, test, deploy)
- **OpenZeppelin Contracts** v5

---

## Project Structure

```
├── src/
│   └── StakingV2.sol
├── test/
│   └── StakingV2.t.sol
├── script/
│   ├── DeployStakingV2.s.sol
│   └── FundRewardPool.s.sol
├── .env.example
└── README.md
```

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Sepolia ETH (from faucet)

### Installation

```bash
git clone https://github.com/yourusername/staking-v2
cd staking-v2
forge install
```

### Environment Setup

```bash
cp .env.example .env
# Edit .env with your PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
```

### Build & Test

```bash
forge build
forge test -vvvv
forge coverage
```

### Deploy

```bash
source .env
forge script script/DeployStakingV2.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

---

## Security Considerations

- **Reentrancy**: All state changes happen before external calls (CEI pattern) + ReentrancyGuard
- **Integer overflow**: Solidity ^0.8.20 built-in overflow protection
- **Access control**: `onlyOwner` modifier on sensitive functions
- **Reward rate manipulation**: Rate changes only affect future rewards, not accrued rewards
- **Emergency withdraw**: Forfeits rewards to prevent reward token drain attacks

---

## Test Coverage

```bash
forge coverage
```

| File          | % Lines | % Statements | % Branches | % Functions |
|---------------|---------|--------------|------------|-------------|
| StakingV2.sol | 100%    | 100%         | 95%+       | 100%        |

---

## License

MIT