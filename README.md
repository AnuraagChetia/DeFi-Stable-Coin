# DeFi Stable Coin

## Overview

The **DeFi Stable Coin** project is a decentralized finance (DeFi) application that implements a stablecoin system. It allows users to deposit collateral, mint stablecoins, and redeem their collateral while maintaining price stability.

## Features

- **Collateral Deposits**: Users can deposit supported tokens as collateral.
- **Stablecoin Minting**: Users can mint stablecoins against their collateral.
- **Collateral Redemption**: Users can redeem their collateral by repaying stablecoins.
- **Oracle Integration**: Uses Chainlink oracles for price feeds.
- **Security Checks**: Ensures proper collateralization ratios.
- **Liquidation Mechanism**: Automatically liquidates undercollateralized positions to maintain system stability.

## Technologies Used

- **Solidity**: Smart contract development.
- **Foundry**: Testing and deployment framework.
- **Chainlink**: For decentralized price feeds.
- **OpenZeppelin**: Security and utility contracts.

## Setup and Installation

1. Clone the repository:
   ```sh
   git clone https://github.com/AnuraagChetia/DeFi-Stable-Coin.git
   cd DeFi-Stable-Coin
   ```
2. Install dependencies:
   ```sh
   forge install  # For Foundry
   ```
3. Compile smart contracts:
   ```sh
   forge build
   ```
4. Run tests:
   ```sh
   forge test
   ```
5. Deploy contracts (modify `.env` with private key and RPC URL):
   ```sh
   forge script script/Deploy.s.sol --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY
   ```

## Project Structure

```
DeFi-Stable-Coin/
│-- contracts/         # Solidity smart contracts
│-- script/            # Deployment scripts
│-- test/              # Unit tests & Fuzz Tests
│-- foundry.toml       # Foundry config
│-- README.md          # Project documentation
```

## Smart Contracts

- **DSCEngine.sol**: Core logic for collateral and stablecoin management.
- **StableCoin.sol**: ERC-20 implementation of the stablecoin.

## Future Enhancements

- Additional collateral types.
- Governance mechanisms.
- Layer-2 integration for lower gas fees.

## License

This project is licensed under the MIT License.

## Contributions

Contributions are welcome! Please fork the repository and create a pull request with improvements.

## Contact

For any queries, reach out to **Anuraag Chetia** via GitHub.
