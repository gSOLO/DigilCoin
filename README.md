# Digital Sigils on the Ethereum Blockchain
The Web3 Layer of the [Digil Project](https://digil.app)  
**Website**: [digil.co.in](https://digil.co.in)

## What is a Digil?
A **Digil** (Digital Sigil) is an ERC-721 **dynamic NFT** that can hold **intrinsic value (ETH)** and accumulate **energy (ERC-20 “coins”)**. Owners and contributors can **charge**, **activate**, **link**, **buff**, **deactivate**, and **discharge** Digils; the contract fairly tracks and redistributes ETH/coins using on-chain rules and events.

Conceptually, a Digil behaves like a **rechargeable node** that can power neighboring nodes when linked. Metaphorically, it is a programmable servitor, a vessel for your intent. By inscribing it on the blockchain, charging it with value, and linking it to other constructs, you create a complex circuit of will that manifests through the movement of value and energy.

> A sigil is a type of symbol used in magic. In modern usage, especially in the context of chaos magic, sigil refers to a symbolic representation of the practitioner's desired outcome.<sup>[?](https://en.wikipedia.org/wiki/Sigil)</sup>

<img src="assets/planes.png" width="1012">

---

## Table of Contents
- [Brand & Terminology](#brand--terminology)
- [Contracts Overview](#contracts-overview)
- [Contribution Update Requirements](#contribution-update-requirements)
- [Planar Tokens & Alignment](#planar-tokens--alignment)
- [Global Configuration](#global-configuration)
- [Per-Token Properties](#per-token-properties)
- [Lifecycle](#lifecycle)
- [Linking & Affinity](#linking--affinity)
- [Buffs & Mechanics](#buffs--mechanics)
- [Vaulting External NFTs](#vaulting-external-nfts)
- [Distributions, Withdrawals & Reclaims](#distributions-withdrawals--reclaims)
- [Opt-Out / Blacklist](#opt-out--blacklist)
- [Admin & Security Notes](#admin--security-notes)
- [Economics & Costs Summary](#economics--costs-summary)
- [How it Works: End-to-End Examples](#how-it-works-end-to-end-examples)

---


## Contribution Update Requirements

When making contract or test behavior changes, keep documentation and comments synchronized in the same PR:

- Review and update affected NatSpec and inline comments so they accurately describe runtime behavior.
- Update this `README.md` whenever setup steps, execution flows, admin actions, or user-facing mechanics change.
- For Desktop Remix IDE testing of `DigilToken`, use this deployment order:
  1. Deploy `DigilCoin` with the default admin account (typically Remix account 0: `0x5B38Da6a701c568545dCfcB03FcB875f56beddC4`).
  2. Deploy `DigilToken` using the same admin as initial owner, the deployed `DigilCoin` address, and `18` for decimals.
  3. Call `grantRole` on `DigilCoin` using role `0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6` (`MINTER_ROLE`) and the deployed `DigilToken` address as `account`.

This role grant is required before `DigilToken` flows that mint DIGIL can succeed.

---

## Brand & Terminology

- **Digil Project** – The broader ecosystem, including the on-chain protocol and frontends at `digil.app`, `digil.co.in`, and related domains.
- **Digital Sigils** – The name of the ERC-721 collection and contract that implements the dynamic NFT logic described in this document.
- **Digil / Digils** – One NFT is called **a Digil**. Informally: “I charged three of my Digils today.”
- **Digil Coin (ERC-20)** – The system’s ERC-20 currency, ticker **DIGIL**, used as “coins” inside the protocol for charging, fees, buffs, governance, and **donor-funded ETH rewards** earned via eligible *spend* (not holding).
- **Digil Governor** – The on-chain governance contract for DigilCoin proposals and timelocked execution, with **quadratic counting** and **NFT-gated voting**.
- **Digital Sigils (ERC-721)** – The NFT collection itself, referenced by the ticker **DIGILS**.
- **ETH vs Coins** – **ETH** represents intrinsic value or “material sacrifice” locked into a Digil; **coins (DIGIL)** represent energy used to drive the system’s mechanics.

---

## Contracts Overview

### Digil Coin (ERC-20)
Used for charge units, feature fees (linking, metadata updates, buffs), and governance. DigilCoin implements **donor-funded ETH rewards** that are uniquely **spend-to-earn** rather than holding-based.

- **Core Token Features**: ERC-20 transferability, burn support, pausable transfer controls, EIP-2612 permit approvals, and OpenZeppelin votes/checkpoint integration.
- **Funding & Earning**: Anyone can fund rewards. Users earn points when an allowlisted spender contract (like the Digil NFT contract) pulls DIGIL from them.
- **Eligibility Model**: Points only accrue for configured spender contracts and only when those contracts call `transferFrom` to pull coins from users.
- **Epochs & Claiming**: Rewards run in 30-day epochs. Users claim ETH based on their points, combined with a days-active multiplier to reward consistent usage over burst spending.
- **Fairness Controls**: Daily and epoch spend caps reduce gaming; minimum daily spend gates active-day bonuses.
- **No Value Trapping**: Unclaimed or unclaimable ETH rolls forward into later epochs so funds remain claimable by participants over time.

### Digil Governor
The on-chain governance contract for DigilCoin that executes approved proposals.

- **Voting**: Uses quadratic counting (weight is the square root of held power) and is **NFT-gated** (voters must own or be approved for a Digil token to cast a ballot).
- **Raw Vote Power Composition**: Delegated liquid votes plus time-locked coin power and a lock-duration bonus.
- **Locking & Outcome Staking**: Users can lock coins for a time-based voting bonus. They can also stake on proposal outcomes while proposals are pending/active, then claim a market-settled payout after finalization (winner takes proportional share of the losing side, canceled proposals refund both sides, and orphaned losing pools can be burned; burners receive a 1% bounty).
- **Execution Safety**: Proposals execute through timelock controls, preserving review windows for privileged actions.

### Digil Timelock
A standard timelock controller that acts as the execution layer for the Governor. Privileged actions in the ecosystem should ultimately be owned and executed by this timelock.

### Digital Sigils (ERC-721)
The core contract that implements the NFT logic and the esoteric machinery of the system. It acts as both the scoreboard and settlement engine for your digital workings, handling economic value, batched payouts, node linking, and visual rendering data.

- **State Machine**: Supports restricted and open tokens, contributor ledgers, batched activation/discharge, and replay-safe state flags.
- **Network Logic**: Includes directional links, affinity-aware transfer efficiency, temporary buffs, and linked-network charge propagation.
- **Treasury Flow**: Tracks pending user distributions in ETH and DIGIL, including owner payouts, contributor claims, and keeper incentives.

---

## Planar Tokens & Alignment

At deployment, the contract mints **21 foundational planar tokens** to the admin. These embed compact affinity data used by the link bonus algorithm. These are the **Archetypes**—the fundamental forces of the Digil reality.

- **Core**: Void, Karma, Kaos
- **Elemental**: Fire, Air, Earth, Water
- **Para-elemental**: Ice, Lightning, Metal, Nature
- **Energy**: Harmony, Discord, Entropy, Exergy, Magick
- **Ethereal**: Aether, World
- **Extended**: Virtual, ILXR

End-user Digils may **align** to a foundational plane during creation. This alignment acts as a permanent hidden attribute that dictates how well your sigil resonates with others in the network.

---

## Global Configuration

The universe's "physics" are controlled by admin dials that dictate the economy. Reconfiguration is performed via:
`configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint256 batchSize)`

- **Coin Rate**: The baseline ERC-20 cost for system actions.
- **Incremental Value**: The global minimum ETH required per coin spent (the material floor).
- **Transfer Value**: The percentage of ETH that flows back to users versus what is retained as a protocol fee (usually a 1% to 10% fee).
- **Batch Size**: How many contributors are processed per transaction during heavy operations like activation and discharge.

These dials have second-order effects across almost every operation: changing them alters contribution requirements, fee pressure, keeper behavior, and how quickly large contributor sets can be settled.

---

## Per-Token Properties

Each Digil maintains a mini-ledger of its own state:

- **Appearance**: Off-chain visual descriptors (styles, colors, gradients) packed efficiently. These have no direct economic effect, but are included in the token’s expressive identity and rendering metadata.
- **Economics**:
  - **Charge (Potential Energy)**: Coins waiting to be activated.
  - **Active Charge (Kinetic Energy)**: Working coins powering buffs and flowing through links.
  - **Value**: The intrinsic ETH the token holds.
  - **Incremental Value**: Per-token ETH floor used during contribution accounting.
  - **Activation Threshold**: The critical mass of coins required to fire the sigil.
- **State & Workflow**: Flags indicating if the token is active, mid-activation, mid-discharge, restricted to a specific whitelist of contributors, or wrapped around an external NFT.
- **Links & Buffs**: Up to 10 connections to other Digils, and any temporary status effects (buffs) currently applied.
- **Attachment Data**: For vaulted NFTs, each token tracks the source collection, source token id, and recall eligibility state.

---

## Lifecycle

The existence of a Digil follows a defined path: **Creating** → **Charging** → **Activating**. Eventually, the energy can be grounded: **Deactivating** and **Discharging**.

### 1. Creating
`createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes data)`

You bring a Digil into existence by defining its required ETH increment and its activation threshold. You can choose to align it with a foundational plane (for an upfront coin fee) and choose whether it accepts open contributions or is restricted to a whitelist. Any ETH sent during creation becomes its foundational value.

### 2. Charging
`chargeToken(uint256 tokenId, uint256 coins)`  
`chargeTokenAs(address contributor, uint256 tokenId, uint256 coins)`

To empower the sigil, participants offer material value (ETH) and energetic value (Coins).
- **Inactive Tokens**: Charging builds "Potential Energy." Participants supply coins and the required minimum ETH.
- **Active Tokens**: If the token has no links, coins become "Kinetic Energy" (Active Charge). If the token is linked, the energy is distributed across the network based on the strength and affinity of those links. Unused ETH goes to the token's owner.
- **Proxy Contribution Support**: `chargeTokenAs` allows sponsored or delegated contribution flows while preserving the canonical contributor ledger.

### 3. Activating
`activateToken(uint256 tokenId)`

Once an inactive token reaches its activation threshold, it can be activated (first call requires owner/approved operator; continuation calls are open to anyone not blacklisted). This transmutes potential energy into active kinetic energy.
- Required contribution ETH is settled to the token owner.
- Contributors only receive a proportional ETH distribution if there is distributable surplus value in the token.
- If there are many contributors, this processes in batches. Anyone can step in to pay gas and finish a batch, earning a **keeper bounty** in DIGIL for doing so.

### 4. Deactivating
`deactivateToken(uint256 tokenId)`

A purely stateful operation that powers down an active construct. No ETH moves. Thematic bleed occurs: a portion of the token's active power is sacrificed to the void (burned) as the cost of breaking the spell.

### 5. Discharging
`dischargeToken(uint256 tokenId)`

The final release dismantling the construct. First call requires owner/approved operator; continuation calls are open to anyone not blacklisted.
- **Inactive Discharge**: Contributors receive a full refund of their ETH and Coins. The owner gets any leftover value.
- **Active Discharge**: Behaves like activation—ETH is settled proportionally. However, any remaining active power is forcefully pushed outward along the token's link graph, strengthening its neighbors before the token is wiped clean.
- **Wrapped NFT Recallability**: If this Digil wraps an external ERC721, an *inactive* discharge clears recallability; an *active* discharge preserves it (the external NFT remains vaulted until recalled).

---

## Linking & Affinity

By calling `linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency)`, you establish a flow of value between two Digils. The strength of this connection relies on **Planar Affinity**—how well the elemental nature of the source aligns with the destination (e.g., Fire to Air vs. Fire to Water).

- Linking splits the required ETH evenly between the two tokens.
- Creating links costs Coins. You receive an **Early-Link Discount** (50% off) for the first two new links on a token.
- You can unlink peer-to-peer Digils via `unlinkToken(uint256 tokenId, uint256 linkId)`, but foundational planar alignments chosen at creation are permanent.
- Link quality combines base efficiency, temporary efficiency bonuses, and affinity bonuses from the planar matrix.

---

## Buffs & Mechanics

Owners can spend an active token's kinetic energy (Active Charge) to apply temporary rituals and enhancements.

### Temporary Buffs
`buffToken(uint256 tokenId, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint16 flags, uint120 appearance, uint256 duration)`

You can mix and match effects for a designated time period (up to 7 days). The cost dynamically scales based on the duration, the number of links, and the magnitude of the requested powers:
- **Efficiency**: Temporarily boosts the base efficiency of all outgoing links.
- **Attunement**: Temporarily shifts your token's frequency to mimic a different Planar Archetype, altering how it synergizes with neighbors.
  - **Synergy Discount**: Attunement magnitude gets a **25% discount** when the chosen plane has a strong affinity with the token's primary planar link.
- **Amplification**: Multiplies any incoming energy landing on the token.
- **Anchor**: Binds energy to the vessel. When discharged, the token retains 25% of its power rather than dissipating completely.
- **Reverb**: Creates a feedback loop. A portion of the energy successfully pushed to outgoing links echoes back to the source.
- **Appearance Override**: The buff payload can also carry short-lived appearance updates for rendering-layer experimentation.

### Stabilization
`stabilizeToken(uint256 tokenId)`

Acts as insurance. By paying a small upfront Coin fee, the token is warded against the 50% power bleed that normally occurs during Deactivation or Vault Recalls.

### Priming
`primeToken(uint256 tokenId)`

Acts as a catalyst for inactive tokens. By paying an upfront Coin fee, the activation threshold is temporarily halved, making it significantly easier to activate the sigil.

### Overcharging
`overchargeToken(uint256 tokenId, uint256 coins)`

A direct conversion feature for owners. You can pay a premium ETH fee to inject raw Active Charge directly into an active token without generating contribution records.

---

## Vaulting External NFTs

Digils can act as "spirit vessels" for other NFTs.

- **Step 1 — Pending Deposit**: Transfer an external ERC-721 into `DigilToken` via `safeTransferFrom`. This records the depositor as the pending owner for that `(externalCollection, externalTokenId)` pair.
- **Step 2 — Finalize Vault**: `vaultToken(address account, uint256 tokenId, bytes data)`  
  Only the recorded depositor can finalize. Finalization charges the Coin vault fee, mints a new Digil wrapper, marks the external NFT as fully vaulted, and stores a reverse index from `(account, externalTokenId)` to the minted Digil id.
- **Unified Exit / Recall**: `recallToken(address account, uint256 externalTokenId)`  
  This function now handles both flows:
  - **Cancel pending deposit**: If the NFT is still pending (not fully vaulted), only the depositor can cancel and receive the NFT back.
  - **Recall fully vaulted NFT**: If the NFT is fully vaulted, an approved operator of the wrapping Digil can recall it only when the attachment is currently marked recallable.
- **Recallability Rules**: Recallability becomes true after a full activation distribution cycle while the NFT remains vaulted. It stays sticky across deactivation, and is cleared only when either (a) recall succeeds, or (b) a full discharge settles while the Digil is inactive.
- **Post-Recall Behavior**: Recalling transfers the external NFT to the current Digil owner, applies active-charge bleed to the Digil shell, and preserves attachment provenance metadata for historical indexing.
 

---

## Distributions, Withdrawals & Reclaims

### Withdrawals
`withdraw()`

When ETH or Coins are owed to you (from activation payouts, refunds, or system rewards), they sit in a pending distribution pool. Calling withdraw pulls these assets to your wallet.
- **Time Bonuses**: If you hold any Digils, letting your pending Coins sit allows them to accrue a time-based bonus over a 7-day yield period.
- **Single Settlement Surface**: Pending ETH and DIGIL from different flows (charging, activation, discharge, keeper rewards) are consolidated behind one user-level withdrawal path.

### Contributor Reclaim
`reclaimContribution(uint256 tokenId)`

A non-custodial safety hatch. If you contributed to a token that has been completely inactive for 90 days, you can unilaterally pull your ETH back out. This forfeits your associated Coins but ensures your ETH is never trapped by a negligent token owner.

---

## Opt-Out / Blacklist

`setOptStatus(bool optOut)`

Accounts can willingly blacklist themselves via this function by paying a small fee. Blacklisted accounts cannot send/receive Digils, participate in charging, or earn Coin bonuses. They can, however, always withdraw their pending ETH. This is useful for individuals who wish to permanently exit the gameplay loop.

---

## Admin & Security Notes

- **Metadata Updates**: `updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes data, string uri)`  
  Token URIs and internal arbitrary data can be updated for a Coin fee, but economic parameters cannot be changed once a token has been charged.
- **Restriction Controls**: `restrictToken(uint256 tokenId, address[] whitelisted)` allows owners of restricted Digils to curate and update contributor access lists with explicit on-chain events.
- **Read-Only Views**: The contract exposes various functions to allow front-ends to easily read the complex, packed state of any Digil:
  - `tokenCharge(uint256 tokenId)`
  - `tokenData(uint256 tokenId)`
  - `tokenBuff(uint256 tokenId)`
  - `tokenContribution(uint256 tokenId, address contributor)`
  - `tokenLinkAt(uint256 tokenId, uint256 index)`
  - `tokenAttachment(uint256 tokenId)`
  - `configuration()`
- **Batch Safety**: Sensitive lifecycle transitions are protected by batch-locks. If a token is mid-activation, it cannot be transferred, charged, or updated until the community finishes the batch processing.
- **Sweep Safety**: The admin can rescue mistakenly sent ERC-20s, but is explicitly blocked from sweeping the native Digil Coin to ensure protocol solvency.

---

## Economics & Costs Summary

- **Operations costing ETH**: Creating restricted tokens, proxy-charging, establishing new links, updating metadata, overcharging, and reclaiming abandoned contributions.
- **Operations costing Coins (DIGIL)**: Aligning with rare planar archetypes, linking to other nodes, applying temporary buffs, priming, stabilizing, vaulting external NFTs, and updating restricted contributor lists.
- **Operations that are free (gas only)**: Activating, Deactivating, unlinking, and standard internal transfers.

*(Note: Exact values fluctuate based on the `configure` dials managed by the Digil Governor).*

---

## How it Works: End-to-End Examples

### 1. Creating and Charging
Alice decides to create a new intent. She calls `createToken(200_000 gwei, 100 * 10**18, false, 12, "ipfs://token-A")`, setting a moderate ETH requirement and an activation threshold of 100 Coins. She pays an extra Coin fee to align her Digil permanently with the "Harmony" plane. Because she leaves it open (unrestricted), anyone can contribute.  
Bob sees her Digil and calls `chargeToken(tokenA, 50 * 10**18)`. He supplies 50 Coins and the necessary ETH. Bob is now logged as a contributor.

### 2. Activating the Sigil
Alice and Bob finish charging the token to 100 Coins. Alice calls `activateToken(tokenA)`. The required contribution ETH is settled to the owner of `tokenA` (Alice). If any extra surplus ETH had been sitting in the token, that surplus would be distributed proportionally to contributors. The token is now marked "Active", and the 100 Potential Coins become 100 Kinetic Coins (Active Charge).

### 3. Linking & Buffing
Alice wants to power up Charlie's Digil. She calls `linkToken(tokenA, tokenC, 120)` to connect her Digil to Charlie's. Because Charlie's Digil is aligned to "Exergy" (which pairs well with her "Harmony" alignment), the contract grants a massive Affinity Bonus.

Before sending power, Alice calls `buffToken(tokenA, 30, 0, 0, 8, 0, 1440)`, spending some of her Active Charge to apply the **Reverb** and **Amplification** effects for 24 hours. Now, when she charges her active token, the power flows directly across the link to Charlie, gets multiplied by the Amplification, and a portion of that successful transfer echoes back to Alice to recharge her own Digil.

### 4. Deactivating and Discharging
Months later, Alice is done with her construct. She calls `deactivateToken(tokenA)`. The token powers down, and half of its remaining kinetic energy is burned into the void. She then calls `dischargeToken(tokenA)`. Because the token is now inactive, discharge runs the inactive unwind path: contribution records are settled/refunded per the discharge rules, any remaining active charge is pushed through links (with normal anchor/rounding behavior), and the token is wiped clean for a new cycle.

---

© Digil — Dynamic NFTs for programmable value and intent.
