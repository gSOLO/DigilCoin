# Digital Sigils on the Ethereum Blockchain
Web3 Layer of the [Digil Project](https://digil.app)  
**Website**: [digil.co.in](https://digil.co.in)

### What is a Digil?

A Digil is a Digital Sigil, an ERC721-based non-fungible token (NFT) on the Ethereum blockchain.  
> A sigil is a type of symbol used in magic. In modern usage, especially in the context of chaos magic, sigil refers to a symbolic representation of the practitioner's desired outcome.<sup>[?](https://en.wikipedia.org/wiki/Sigil)</sup>  

Digil Tokens represent digital sigils with intrinsic value (Ether and ERC20 tokens) and unique mechanics like charging, activation, linking, and distribution, enabling a gamified and value-driven ecosystem.

<img src="assets/tokens.png" width="900">

## Digil Coin | ERC20 Token
**Symbol**: DIGIL  
**Contract Address**: Coming Soon  

The Digil Coin is an ERC20 token used for charging tokens, linking, and other operations within the DigilToken contract.

## Digil Token | ERC721 Token (NFT)
**Symbol**: DiGiL  
**Contract Address**: Coming Soon

The DigilToken contract is an ERC721-compliant NFT contract with advanced features for creating, charging, activating, and linking tokens. It integrates with an ERC20 token (Digil Coin) and supports external ERC721 token interactions.

### Contract Configuration

**Coin Rate**: Determines the number of Digil Coins required for actions like linking tokens, updating URIs, or opting out. It also sets the maximum bonus coins awarded during withdrawals.  

**Minimum Incremental Value**: The minimum Ether (in wei) required per Digil Coin to charge a token. It also defines the cost for actions like restricting, discharging, or updating tokens. Default: 100,000 gwei.  

**Transfer Value**: A fraction (90-100%) of the Minimum Incremental Value used to calculate value distributions to contributors and token owners during charging or activation. Default: 95,000 gwei.  

**Batch Size**: Limits the number of contributors processed per transaction in batch operations (e.g., distribution, discharge). Default: 350.

### Tokens

#### Basic Properties

**Charge**: The total Digil Coins contributed to the token.  
**Active Charge**: Coins accumulated from active token operations or transfers from linked tokens.  
**Activation Threshold**: The minimum number of Digil Coins required to activate a token.  

**Value**: The Ether (in wei) accumulated by the token, beyond the charge-related value.  
**Incremental Value**: The Ether required per Digil Coin to charge the token (can be zero).  
**Incremental Charge Value**: The Ether derived from the token’s charge multiplied by its incremental value.  

**Links**: An array of token IDs or plane IDs the token is linked to (maximum 10 links). Links facilitate coin and value transfers during charging.  

**Contributors**: Addresses that have charged the token, tracked to enable value distribution or refunds during activation or discharge.  

**Restricted**: A flag indicating whether only whitelisted addresses can contribute to or link to the token.  

**Metadata**: Each token stores a URI (e.g., `https://digil.co.in/token/<plane_name>`) and arbitrary `data` (bytes) for additional information.

#### Planes

Planes are special tokens (IDs 0-20) minted during contract deployment, representing thematic elements. Tokens can be linked to planes at creation, influencing affinity bonuses for linked charges.  

- **Core Planes**: Void<sup>1</sup>, Karma<sup>2</sup>, Kaos<sup>3</sup>  
- **Elemental Planes**: Fire<sup>4</sup>, Air<sup>5</sup>, Earth<sup>6</sup>, Water<sup>7</sup>  
- **Paraelemental Planes**: Ice<sup>8</sup>, Lightning<sup>9</sup>, Metal<sup>10</sup>, Nature<sup>11</sup>  
- **Energy Planes**: Harmony<sup>12</sup>, Discord<sup>13</sup>, Entropy<sup>14</sup>, Exergy<sup>15</sup>, Magick<sup>16</sup>  
- **Ethereal Planes**: Aether<sup>17</sup>, World<sup>18</sup>  
- **Extended Planes**: Virtual<sup>19</sup>, ILXR<sup>20</sup>  

Each plane has associated metadata defining affinity relationships, impacting link efficiency.

#### Creation

When **creating** a token, you specify:  
- **Incremental Value**: Ether required per Digil Coin for charging (must be at least the Minimum Incremental Value if non-zero).  
- **Activation Threshold**: Digil Coins needed to activate the token.  
- **Restricted**: Whether contributions are limited to whitelisted addresses.  
- **Plane**: An optional plane (1-18) to link to, requiring Digil Coins based on the plane type:  
  - Void, Karma, Kaos: 5x Coin Rate  
  - Paraelemental (Ice, Lightning, Metal, Nature): 1x Coin Rate  
  - Energy (Harmony, Discord, Entropy, Exergy, Magick): 25x Coin Rate  
  - Ethereal (Aether, World): 100x Coin Rate  
- **Data**: Arbitrary bytes stored with the token.  

Any Ether sent during creation is added to the token’s value. Restricting a token at creation requires Ether equal to the greater of the token’s or contract’s incremental value.

#### Charging

Digil Coins can be used to **charge** a token, increasing its `charge` and potentially its `value`. If the token has an `incrementalValue`, Ether must be sent proportional to the coins charged (e.g., `incrementalValue * coins / coinMultiplier`). Excess Ether beyond this requirement is added to the token’s `value`.  

- **Inactive Tokens**: Contributions are tracked per address, and coins/value are recorded for later distribution.  
- **Active Tokens**: Coins are added to `activeCharge`, or distributed to linked tokens based on link efficiency and affinity bonuses.  

Charging requires the contributor to be whitelisted if the token is restricted. The contract owner or approved operators can charge on behalf of others.

#### Linking

Tokens can be **linked** to other tokens or planes (up to 10 links) to enable coin and value transfers during charging. Linking requires:  
- Ether: Sum of the source and destination token’s `incrementalValue`.  
- Digil Coins: Based on the link’s efficiency (1-255%) and existing link count.  

**Link Efficiency**:  
- **Base Efficiency**: A percentage (e.g., 100 = 100%) determining coin transfer rates.  
- **Affinity Bonus**: Additional efficiency for plane-linked tokens, calculated based on plane relationships (strong, weak, or same). For example:  
  - Strong affinity (e.g., Fire to Air): 2x efficiency.  
  - Weak affinity: 0.5x efficiency.  
  - Ethereal planes (Aether, World): Up to 4x bonus.  

Linked tokens distribute coins/value during charging, with efficiency and bonuses applied. Tokens can be **unlinked** to remove these connections.

#### Activation

A token can be **activated** when its `charge` meets or exceeds its `activationThreshold`. Activation:  
- Distributes the token’s `value` to contributors proportional to their contributions.  
- Transfers the `charge` to `activeCharge` for the token owner.  
- Processes contributors in batches (2x `batchSize` per transaction).  

Once activated, the token becomes `active`, enabling linked charging mechanics. An active token can be **deactivated** if its `charge` is zero, requiring Ether equal to the token’s `incrementalValue`.

#### Discharge

**Discharging** a token resets its contributions and redistributes value:  
- **Inactive Tokens**: Returns contributed coins and Ether to contributors; remaining `value` goes to the token owner.  
- **Active Tokens**: Distributes the `incrementalChargeValue` to the token owner; `value` is split among contributors.  

Discharge requires Ether proportional to the number of links (minimum: `max(_incrementalValue, token.incrementalValue) * links`). It processes contributors in batches (`batchSize` for distribution, 2x `batchSize` for contributor reset). If a token is linked to an external ERC721 token, the external token’s address remains as a contributor unless recalled.

#### Restricted Tokens

Tokens can be **restricted** to limit contributions and linking to whitelisted addresses.  
- **Whitelisting**: Addresses are added to a token’s whitelist by the owner or approved operators. Whitelisted addresses cannot be removed.  
- **Automatic Whitelisting**: Token owners are automatically whitelisted upon transfer.  
- **Restriction**: Can be set at creation or later, requiring Ether (`max(_incrementalValue, token.incrementalValue)`).  

Restriction limits value distribution to whitelisted contributors during activation.

#### Contract Tokens

External **ERC721 tokens** sent to the contract are wrapped as new Digil Tokens:  
- **Creation**: The new Digil Token has an `incrementalValue` equal to the greater of the contract’s `minimumIncrementalValue` or the external token’s `incrementalValue` (if a Digil Token).  
- **Metadata**: The external token’s contract address and ID are appended to the Digil Token’s URI as query parameters.  
- **Recall**: The external token can be **recalled** to the Digil Token’s owner after activation or discharge, distributing the Digil Token’s `activeCharge` to the owner.  

The external token’s contract address is added as a contributor to the Digil Token.

#### Withdrawals

When a token is charged, activated, or discharged, it generates pending distributions of Digil Coins and Ether for contributors or owners. These can be **withdrawn**:  
- **Pending Distributions**: Coins and Ether accumulated from token operations.  
- **Bonus Coins**: Awarded every 15 minutes (up to `coinRate`) to addresses holding Digil Tokens, Digil Coins, or pending Ether distributions.  

Withdrawals are non-reentrant and transfer Ether via safe methods, reverting coins to pending if the transfer fails.

### Blacklist and Opt-Out

An address can be **blacklisted** to block interactions with the contract:  
- **Opt-Out**: An address can opt out by sending Ether (`_incrementalValue * _coinRate / _coinMultiplier`), preventing token transfers, withdrawals, and actions like charging, linking, or activation.  
- **Opt-In**: An opted-out address can opt back in using the same process.  
- **Admin Blacklist**: The contract owner can blacklist addresses (not implemented in the contract).  

Blacklisted addresses cannot interact with tokens but can be rescued by the owner if inactive for 365 days and meeting value/charge criteria.

### Token Rescue

The contract owner can **rescue** tokens from blacklisted or inactive (365 days without activity) addresses if:  
- The address is blacklisted, or  
- The token has non-zero `value`, or it’s inactive with contributors, charge, and `incrementalValue`.  

Rescued tokens are transferred to a specified address, clearing approvals.

### Additional Features

- **Token Updates**: Approved operators can update a token’s `incrementalValue`, `activationThreshold`, `data`, or `uri`. Updates to `data` or `uri` require 1000x `coinRate` Digil Coins (non-owner) and Ether (`incrementalValue + _incrementalValue`).  
- **Batch Processing**: Activation and discharge process contributors in batches to manage gas costs.  
- **Security**: Uses OpenZeppelin’s ReentrancyGuard, safe Ether transfers, and blacklist checks to prevent unauthorized actions.  
- **Initial Tokens**: 20 plane tokens (IDs 0-19) are minted at deployment, with token 0 restricted.  

### Usage Notes

- **Gas Costs**: Operations like discharging or linking multiple tokens can be gas-intensive. Batch processing mitigates this but requires multiple transactions for large contributor lists.  
- **Economic Model**: The dual-token system (Ether and Digil Coins) incentivizes participation through bonuses and value accrual.  
- **Plane Affinities**: Strategic linking to planes with strong affinities maximizes charging efficiency.  

For more details, refer to the contract code or contact [security@digil.co.in](mailto:security@digil.co.in).