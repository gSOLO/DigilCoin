# Digil: Digital Sigils on the Ethereum Blockchain
The Web3 Layer of the [Digil Project](https://digil.app)  
**Website**: [digil.co.in](https://digil.co.in)

### What is a Digil?

A Digil is a **Digital Sigil**, an ERC721-based dynamic non-fungible token (dNFT) on the Ethereum blockchain.
> A sigil is a type of symbol used in magic. In modern usage, especially in the context of chaos magic, sigil refers to a symbolic representation of the practitioner's desired outcome.<sup>[?](https://en.wikipedia.org/wiki/Sigil)</sup>

Unlike static collectibles, Digil Tokens are dynamic entities with intrinsic value (Ether and an associated ERC20 token). They feature a complex lifecycle with unique mechanics like charging, activation, and linking, creating a gamified, value-driven ecosystem.

<img src="assets/tokens.png" width="900">

## Core Components

### Digil Coin | ERC20 Token
**Symbol**: DIGIL
**Contract Address**: TBD

The Digil Coin is the primary utility token of the ecosystem. It is used for charging tokens, paying for advanced operations like linking, and interacting with the core mechanics of the DigilToken contract.

### Digil Token | ERC721 NFT
**Symbol**: DDIGIL
**Contract Address**: TBD

The DigilToken contract is an ERC721-compliant NFT contract that brings Digils to life. It manages their creation, lifecycle, and interactions, integrating deeply with the Digil Coin and native Ether.

## Key Concepts and Mechanics

### Contract Configuration (Owner-Controlled)

The contract owner can configure the following global parameters:

| Parameter | Description | Default Value |
| :--- | :--- | :--- |
| **Coin Rate** | Base rate for calculating fees (in Digil Coins) for actions like linking or updating tokens. Also sets the cap for withdrawal bonuses. | `100 * 10**decimals` |
| **Incremental Value** | The base ETH value (in wei) that must accompany each Digil Coin during charging. This value cannot be set to zero. | `100,000 gwei` |
| **Transfer Value** | A fraction (90-100%) of the `Incremental Value` that is distributed to users during operations like activation. | `95,000 gwei` |
| **Batch Size** | The number of contributors processed per transaction during batched operations (distribution, discharge). | `350` |

### Token Properties

Each Digil has a rich set of properties that define its state and power:

*   **Charge**: The total Digil Coins contributed to a token by users.
*   **Active Charge**: Digil Coins accumulated by an *active* token through its own operations or received from linked tokens.
*   **Value**: The intrinsic Ether (in wei) accumulated by the token from various operations, separate from its charge.
*   **Incremental Value**: A per-token setting for the ETH required to charge it. Must be `>=` the global `IncrementalValue` if not zero.
*   **Activation Threshold**: The amount of `Charge` required to activate the token.
*   **Links**: An array of up to **10** token IDs this Digil is linked to. Links are directional and enable coin/value transfers.
*   **Contributors**: A list of addresses that have charged the token, used for value distribution.
*   **Restricted**: A flag to limit contributions to whitelisted addresses only.

### The Token Lifecycle

#### 1. Creation

New Digils are created by calling `createToken`. Users can specify:
*   **Incremental Value**: The ETH-per-coin cost for charging this specific token.
*   **Activation Threshold**: The charge needed for activation.
*   **Restricted**: A boolean to enable whitelisting from the start. This requires an initial ETH deposit.
*   **Plane**: An optional link to a "Plane" token (IDs 1-18) at creation, which requires a Digil Coin fee based on the plane's tier.
*   **Data**: Arbitrary `bytes` to store extra on-chain information.

Any ETH sent during creation is added directly to the new token's `Value`.

#### 2. Charging

Charging is the process of imbuing a Digil with Digil Coins and Ether.
*   **Inactive Tokens**: A `charge` action is a contribution. The coins and a proportional amount of ETH are logged against the contributor's address. Any excess ETH adds to the token's `Value`.
*   **Active Tokens**: A `charge` action flows through the token's links. Coins and value are distributed to linked tokens based on their `LinkEfficiency` and `AffinityBonus`.

#### 3. Activation

When a token's `Charge` meets its `ActivationThreshold`, it can be activated.
*   This is a **batched operation** that may require multiple transactions.
*   During activation, the token's `Value` is distributed to its contributors.
*   The total `Charge` is converted into `ActiveCharge` for the token's owner.
*   The token's state changes to `active`.

An active token can later be **deactivated** if its `charge` is zero by paying a fee.

#### 4. Discharge

Discharging resets a token's contributions and redistributes its value.
*   This is also a **batched operation**.
*   **If Inactive**: Contributed coins and ETH are refunded to the original contributors.
*   **If Active**: The token's accumulated value is distributed to the owner and contributors.
*   Discharging requires an ETH fee that scales with the token's number of links.

### Linking & Planes

Linking is a strategic element that allows active tokens to interact.

*   **Linking Tokens**: A user can link their token to up to 10 other Digils. This costs both ETH and a scaling amount of Digil Coins.
*   **Link Efficiency**: When an active token is charged, it distributes coins to its links based on:
    *   **Base Efficiency (1-255%)**: The core transfer rate of the link.
    *   **Affinity Bonus**: An additional bonus calculated if the linked tokens are associated with planes. Strong affinities (e.g., Fire -> Air) can double the transferred amount, while weak ones can halve it.

#### Planes

Planes are special tokens (IDs 0-20) minted during contract deployment, representing thematic elements. Tokens can be linked to planes at creation, which influences affinity bonuses when linking to other plane-aligned tokens.

- **Core Planes**: Void<sup>1</sup>, Karma<sup>2</sup>, Kaos<sup>3</sup>
- **Elemental Planes**: Fire<sup>4</sup>, Air<sup>5</sup>, Earth<sup>6</sup>, Water<sup>7</sup>
- **Paraelemental Planes**: Ice<sup>8</sup>, Lightning<sup>9</sup>, Metal<sup>10</sup>, Nature<sup>11</sup>
- **Energy Planes**: Harmony<sup>12</sup>, Discord<sup>13</sup>, Entropy<sup>14</sup>, Exergy<sup>15</sup>, Magick<sup>16</sup>
- **Ethereal Planes**: Aether<sup>17</sup>, World<sup>18</sup>
- **Extended Planes**: Virtual<sup>19</sup>, ILXR<sup>20</sup>

Each plane has associated on-chain metadata that defines its affinity relationships, directly impacting link efficiency bonuses.

### Special Token Types & Interactions

*   **Restricted Tokens**: The token owner can maintain a whitelist of addresses allowed to contribute. The token's owner is always automatically whitelisted.
*   **Contract Tokens (ERC721 Vault)**: The contract can act as a vault for external ERC721 NFTs.
    *   When an external NFT is sent to the contract, a new Digil is automatically minted to represent it.
    *   The Digil's URI is updated to reference the original NFT.
    *   After activation, the owner can **recall** the original NFT, and the Digil's `activeCharge` is paid out to them.

## Security & Trust

This contract includes several features designed to protect users and provide recovery paths.

*   **Opt-Out/Blacklist**: Users can pay a fee to opt-out of the system, preventing them from receiving tokens or interacting with the contract. They can opt back in at any time.
*   **Reentrancy Guard**: Critical functions involving external calls are protected against reentrancy attacks.
*   **Owner Powers**: The contract owner has administrative powers to configure key economic parameters. This allows for flexibility and recovery but requires user trust.
*   **Token Rescue Mechanism**: To balance the owner's power and protect users, a robust rescue mechanism is in place:
    *   **Stalled Operations**: If a token gets stuck in a multi-step operation (like `activate` or `discharge`), it can be rescued by the owner after a **7-day** inactivity period. This provides a fast recovery path from operational failures.
    *   **Long-Term Abandonment**: If a token is completely inactive for **180 days** *and* has value locked in it, it can be rescued by the owner. This prevents assets from being permanently lost.
    *   **Blacklisted Owners**: Tokens owned by blacklisted addresses can also be rescued.

## User Actions and Distributions

*   **Withdrawals**: ETH and Digil Coin distributions generated from token operations are held in a pending balance for each user. These can be withdrawn at any time.
*   **Bonus Coins**: To incentivize participation, users who hold Digil Tokens or Digil Coins are eligible to receive bonus coins, claimable every 15 minutes during a `withdraw` transaction.