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