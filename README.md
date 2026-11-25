# Digital Sigils on the Ethereum Blockchain
The Web3 Layer of [Digil Studio](https://digil.studio)  
**Website**: [digil.xyz](https://digil.xyz)

## What is a Digil?
A **Digil** (Digital Sigil) is an ERC-721 **dynamic NFT** that can hold **intrinsic value (ETH)** and accumulate **energy (ERC-20 “coins”)**. Owners and contributors can **charge**, **activate**, **link**, **buff**, **deactivate**, and **discharge** Digils; the contract fairly tracks and redistributes ETH/coins using on-chain rules and events.

Conceptually, a Digil behaves like a **rechargeable node** that can power neighboring nodes when linked. Metaphorically, it is a programmable servitor, a vessel for your intent. By inscribing it on the blockchain, charging it with value, and linking it to other constructs, you create a complex circuit of will that manifests through the movement of value and energy.

> A sigil is a type of symbol used in magic. In modern usage, especially in the context of chaos magic, sigil refers to a symbolic representation of the practitioner's desired outcome.<sup>[?](https://en.wikipedia.org/wiki/Sigil)</sup>

<img src="assets/planes.png" width="1012">

---

## Table of Contents
- [Brand & Terminology](#brand--terminology)
- [Contracts Overview](#contracts-overview)
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
- [Local Validation](#local-validation)
- [Test Coverage](#test-coverage)
- [Script Maintenance](#script-maintenance)
- [Remix VM Deployment and Tests](#remix-vm-deployment-and-tests)
- [How it Works: End-to-End Examples](#how-it-works-end-to-end-examples)

---

## Brand & Terminology

- **Digil Project** – The broader ecosystem, including the on-chain protocol and frontends at `digil.studio`, `digil.app`, `digil.xyz`, and related domains.
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
- **Funding & Earning**: Anyone can fund rewards. Users earn points when a configured spender contract collects a nonrefundable DIGIL feature fee through `spendFrom(address payer, uint256 amount)`.
- **Eligibility Model**: The fee consumes the payer's allowance and transfers DIGIL to the caller. Its configured spend weight determines the payer's points. Ordinary `transfer` and `transferFrom` calls, all charging deposits (including those later activated), refunds, governance locks, and stakes earn no points. Paid plane alignment, vaulting, metadata changes, linking/upgrades, priming, and stabilization qualify. Free alignment choices and active-charge consumption do not create eligible DIGIL spending.
- **Spender Trust**: `CONFIG_ROLE` must only enable contracts that distinguish nonrefundable fees from deposits. A zero weight disables rewards without disabling fee collection. External integrations must adopt `spendFrom`; an ordinary `transferFrom` pull is no longer eligible.
- **Epochs & Claiming**: Rewards run in 30-day epochs. Users claim ETH based on their points, combined with a days-active multiplier to reward consistent usage over burst spending. User history spans 12 stored epochs. An untouched address reads as all zeros in stored epoch zero. Later stored epochs without a user record revert with `NothingToClaim`, and overwritten epochs revert with `EpochNotFound`. Epoch start timestamps use `uint48` in `currentEpochStart()`, `getEpoch()`, and `EpochAdvance(uint32,uint48)`.
- **Fairness Controls**: Daily and epoch spend caps reduce gaming; minimum daily spend gates active-day bonuses.
- **No Value Trapping**: Unclaimed or unclaimable ETH rolls forward into later epochs so funds remain claimable by participants over time.

### Digil Governor
The on-chain governance contract for DigilCoin that executes approved proposals.

- **Voting**: A voter needs positive snapshot power and an owned or approved Digil NFT. The ballot counts the square root of that power. A zero-power attempt leaves the NFT available for that proposal.
- **Raw Vote Power Composition**: Delegated liquid votes plus time-locked coin power and a lock-duration bonus.
- **Locking & Outcome Staking**: Users can lock coins for a time-based voting bonus and stake on proposal outcomes while proposals are pending/active. Markets predict the final ballot, not execution: a passing ballot settles For; ties, failed quorum, and defeated ballots settle Against. Only cancellation before voting finishes refunds both sides. Later cancellation, queueing, or execution never changes settlement. Winners receive principal plus their proportional share of the losing pool; orphaned losing pools can be burned with a 1% caller bounty.
- **Market Finalization**: Anyone may call `finalizeMarket(proposalId)`; `claim` and `burn` also finalize lazily. `marketOutcome(proposalId)` returns `0` (unsettled), `1` (Against), `2` (For), or `3` (early-cancellation refund). `MarketFinalized(uint256 indexed proposalId, uint8 outcome)` is emitted once. The exact voting deadline is still an active timepoint; ordinary ballot finalization requires a later clock value. Early cancellation records its refund immediately, even if users claim much later.
- **Accepted Governance Limitations**: NFT gating prevents reuse of a credential per proposal, not duplicate identities. Address splitting remains advantageous under quadratic counting; quorum remains 4% of the square root of snapshot supply, not 4% of raw tokens. Linear voting would remove the square-root splitting advantage but concentrate influence in large holders. Identity-backed quadratic voting would require additional uniqueness, privacy, recovery, and revocation infrastructure. The current model and lock bonuses are retained intentionally.
- **Execution Safety**: Timelocked proposals may spend treasury DIGIL held by the timelock and recover unrelated assets held by the Governor. The Governor rejects every `relay` targeting DIGIL to protect locks and market stakes. Surplus DIGIL sent directly to the Governor is also outside relay recovery.
- **Economic Control Path**: Governor changes Digil economics indirectly—by governing privileged calls once ownership/admin roles are handed to the timelock/governance stack.

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

Only planes **1..18** are user-alignable during `createToken`.

- **User-alignable planes (1..18)**: Void through World.
- **Extended/admin planes (19..20)**: Virtual and ILXR; minted at deploy and reserved for extended/admin planar behavior.

End-user Digils may **align** to a user-alignable foundational plane during creation. This alignment acts as a permanent hidden attribute that dictates how well your sigil resonates with others in the network.

---

## Global Configuration

The universe's "physics" are controlled by admin dials that dictate the economy. Reconfiguration is performed via:
`configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint16 batchSize)`

- **Coin Rate**: The baseline ERC-20 cost for system actions.
- **Incremental Value**: The global minimum ETH required per coin spent (the material floor).
- **Transfer Value**: The percentage of ETH that flows back to users versus what is retained as a protocol fee (usually a 1% to 10% fee).
- **Batch size** defaults to 128. The owner can set 32–2,048 contributors per settlement call. Use **256 as the recommended upper bound on Osaka**. With fresh payouts and ten links, the highest measured 256-contributor batch used 14.22 million of the 16.78 million gas available per transaction. Before raising it, benchmark activation and discharge on the target chain. If a batch runs out of gas, the owner can lower the setting and settlement resumes from the last successful batch with keeper eligibility preserved. Renouncing ownership permanently fixes the setting.

Activation and discharge use the ETH fee and DIGIL bonus rates in effect when settlement starts. Batch size changes apply on the next call, including during an ongoing settlement.

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
- **Links & Buffs**: Up to 10 total stored links, including a foundational planar alignment link when present. In practice, a Digil aligned to a foundational Plane has one slot already occupied, leaving fewer peer-to-peer Digil links available. Temporary status effects (buffs) may also be applied.
- **Attachment Data**: For vaulted NFTs, each token tracks the source collection, source token id, and recall eligibility state.

---

## Lifecycle

The existence of a Digil follows a defined path: **Creating** → **Charging** → **Activating**. Eventually, the energy can be grounded: **Deactivating** and **Discharging**.

### 1. Creating
`createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes data)`

You bring a Digil into existence by defining its required ETH increment and its activation threshold. You can choose to align it with a foundational plane (for an upfront coin fee) and choose whether it accepts open contributions or is restricted to a whitelist. Any ETH sent during creation becomes its foundational value.

Creation ETH minimums are explicit:
- Base required ETH is always at least the global incremental value.
- If `restricted == true` and `incrementalValue > global floor`, required ETH becomes that higher `incrementalValue`.
- If `restricted == false`, setting a higher per-token `incrementalValue` does **not** raise the creation minimum above the global floor (it still affects later charging requirements).
- **Welcome gift**: Each account can earn one DIGIL on its first successful paid `createToken` or `vaultToken` call, with one shared eligibility flag. Transfers and constructor planar mints grant no gift. Previously receiving or selling NFTs neither consumes nor restores paid-creation eligibility. Collector-yield checkpoints are independent of this gift.

### 2. Charging
`chargeToken(uint256 tokenId, uint256 coins)`  
`chargeTokenAs(address contributor, uint256 tokenId, uint256 coins)`

To empower the sigil, participants offer material value (ETH) and energetic value (Coins).
- **Inactive Tokens**: Charging builds "Potential Energy." Participants supply coins and the required minimum ETH.
- **Active Tokens**: If the token has no links, coins become "Kinetic Energy" (Active Charge). If the token is linked, the energy is distributed across the network based on the strength and affinity of those links. When a destination's price multiplication overflows, the source keeps that link's base charge and continues charging the other links. The source owner receives unused ETH through the usual distribution after the protocol fee.
- **Proxy Contribution Support**: `chargeTokenAs` allows sponsored or delegated contribution flows while preserving the canonical contributor ledger.
- **Participation Definition**: In `chargeTokenAs`, participation means who receives contribution attribution (`contributor`), not who pays gas/calls. Both caller and contributor must be opted in (not blacklisted) for the charge to proceed.
- **Proxy ETH Floor**: For sponsored/proxy charging (`contributor != msg.sender`), the call must provide at least `max(token.incrementalValue, globalIncrementalValue)` in ETH, even if `token.incrementalValue == 0`. By contrast, direct self-charging on a token with `token.incrementalValue == 0` can be done with `0` ETH.

### 3. Activating
`activateToken(uint256 tokenId)`

Once an inactive token reaches its activation threshold, it can be activated (first call requires owner/approved operator; continuation calls are open to anyone not blacklisted). This transmutes potential energy into active kinetic energy.
- Required contribution ETH is settled to the token owner.
- Contributors only receive a proportional ETH distribution if there is distributable surplus value in the token.
- If there are more contributors than the batch size when activation starts, every progressing batch, including the final batch, receives a **keeper bounty** totaling 1% of the actual DIGIL deposited directly by those contributors and committed by activation. Linked charge, affinity/synthetic charge, and reclaimed contributions do not fund this bounty. Cumulative rounding carries sub-unit remainders between batches. Single-batch activation receives no keeper bounty.

**Activation timeline (permission split):**
- **Step A — First call (`activating == false`)**: only owner/approved operator can start activation; token must satisfy threshold and be inactive.
- **Step B — Mid-batch (`activating == true`)**: any non-blacklisted address can submit continuation calls.
- **Step C — Completion**: final continuation call flips token to active, clears activation lock, and consumes PRIMED if present.


### 4. Deactivating
`deactivateToken(uint256 tokenId)`

A purely stateful operation that powers down an active construct. No ETH moves. Thematic bleed occurs: a portion of the token's active power is sacrificed to the void (burned) as the cost of breaking the spell.

### 5. Discharging
`dischargeToken(uint256 tokenId)`

The final release dismantling the construct. First call requires owner/approved operator; continuation calls are open to anyone not blacklisted.
- **Inactive Discharge**: Contributors receive a full refund of their ETH and Coins. The owner gets any leftover value.
- **Active Discharge**: Uses activation-style settlement (`_distribute(..., false)`): contributor ETH is distributed proportionally from token value, and captured contribution charge is converted into `activeCharge` before final active-power propagation. Any remaining active power is then pushed outward along the token's link graph, strengthening neighbors before contributor/distribution state is cleared. Active discharge does **not** itself deactivate the Digil; call `deactivateToken(uint256 tokenId)` separately if you want it powered down.
- **ETH Bootstrap Rules (exactly as implemented)**:
  - Inactive-path first call and active-path first call both require exact ETH:
    - `msg.value == max(token.incrementalValue, globalIncrementalValue) * max(links.length, 1)`.
  - This required first-call ETH is enforced only when `discharging == false` (the cycle bootstrap call). If there are more contributors than the batch size at bootstrap, 10% is reserved for keepers and the remainder goes to the protocol value pool. Otherwise the entire fee goes to the protocol.
  - Continuation batch calls in the same discharge cycle must send exactly `0` ETH. Any non-zero `msg.value` on continuation reverts.
- **Wrapped NFT Recallability**: If this Digil wraps an external ERC721, an *inactive* discharge clears recallability; an *active* discharge preserves it (the external NFT remains vaulted until recalled).
- **Discharge keeper rewards**: The reserved ETH budget is divided by processed contributor count using cumulative rounding. Every progressing batch, including the final batch, earns its ETH-only keeper reward through `withdraw()`. Recorded contributor principal is refunded in full on the inactive path. Eligibility and the ETH budget are fixed at bootstrap even if the configured batch size changes. Empty continuations do not create rewards.

**Discharge timeline (fee + continuation):**
- **Step A — First call (`discharging == false`)**: only owner/approved operator can start; caller must send **exactly** `max(globalIncrementalValue, tokenIncrementalValue) * max(1, links.length)` ETH.
- **Step B — Mid-batch (`discharging == true`)**: any non-blacklisted address can continue processing.
- **Step C — Continuations fee rule**: every continuation call must send **exactly `0` ETH**.
- **Step D — Completion**: lock clears; contributors are fully settled for that epoch; temporary buff fields are reset while persisted appearance payload remains.


### Maintenance During Lifecycle
`updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes data, string uri)`

- When `uri` and `data` are both empty, `msg.value` must equal exactly `0`.
- When either `uri` or `data` is non-empty, `msg.value` must equal exactly `max(currentIncrementalValue, newIncrementalValue, globalIncrementalValue)`.
- Required ETH from this call is routed into the protocol value pool.
- Identical parameters or metadata do not reset inactivity. Existing metadata submission fees still apply when non-empty data or a URI is supplied, even if its contents are unchanged.

---

## Linking & Affinity

By calling `linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency)`, you establish a flow of value between two Digils. The strength of this connection relies on **Planar Affinity**—how well the elemental nature of the source aligns with the destination (e.g., Fire to Air vs. Fire to Water).

- Linking splits the required ETH evenly between the two tokens.
- Exact link ETH minimum:
  - `requiredValue = source.incrementalValue + destination.incrementalValue`
- Creating links costs Coins. You receive an **Early-Link Discount** (50% off) when a new link leaves the token with **`<= 2` total stored links**.
- A foundational plane alignment link (set during creation) **counts toward that stored-link total**.
- Therefore, aligned tokens will usually get the early-link discount on **only their first peer-to-peer Digil link**.
- You can unlink peer-to-peer Digils via `unlinkToken(uint256 tokenId, uint256 linkId)`, but foundational planar alignments chosen at creation are permanent.
- Link quality combines base efficiency, temporary efficiency bonuses, and affinity bonuses from the planar matrix.
- **Permanent affinity upgrades are intentional**: Linking or upgrading while attuned can permanently increase the cached affinity bonus. Expiration or replacement of that attunement does not reduce the stored upgrade; only the separate temporary efficiency boost expires.

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
- **Appearance Override**: The buff payload can also carry appearance updates for rendering-layer experimentation. Unlike the temporary buff effect fields, the stored appearance payload persists across discharge until explicitly changed again.

### Stabilization
`stabilizeToken(uint256 tokenId)`

Acts as insurance. By paying a small upfront Coin fee, the token is warded against the 50% power bleed that normally occurs during Deactivation or Vault Recalls. A discharge in progress blocks the purchase before the fee is collected.

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
- **Deposit Mode Requirement**: Only `safeTransferFrom` deposits are supported; direct safe-mint to DigilToken is rejected.
- **Step 2 — Finalize Vault**: `vaultToken(address account, uint256 externalTokenId, bytes data)`  
  Only the recorded depositor can finalize. Finalization charges the Coin vault fee, mints a new Digil wrapper, marks the external NFT as fully vaulted, and stores a reverse index from `(account, externalTokenId)` to the minted Digil id. The wrapper is created with an activation threshold of `0`. `externalTokenId` refers to the deposited token ID from the external ERC721 collection (`account`), not a Digil token ID.
- **Paid vault rewards**: The nonrefundable vault fee (`10 * coinRate`) earns donor-reward points and qualifies for the account's one-time welcome gift, shared with ordinary paid creation.
- **Unified Exit / Recall**: `recallToken(address account, uint256 externalTokenId)`  
  This function now handles both flows:
  - **Cancel pending deposit**: If the NFT is still pending (not fully vaulted), only the depositor can cancel and receive the NFT back.
  - **Recall fully vaulted NFT**: If the NFT is fully vaulted, an approved operator of the wrapping Digil can recall it only when the attachment is currently marked recallable.
- **Recallability Rules**: Recallability is enforced through the attachment's stored `recallable` flag. For vaulted wrappers, that flag is updated during the wrapper's lifecycle processing and can become true under the normal zero-threshold activation/distribution path. It stays sticky across deactivation, and is cleared only when either (a) recall succeeds, or (b) a full discharge settles while the Digil is inactive.
- **Post-Recall Behavior**: Recalling transfers the external NFT to the current Digil owner, applies active-charge bleed to the Digil shell, and preserves attachment provenance metadata for historical indexing.
- **Current wrapper identity**: `tokenAttachment` reports custody and recallability only when the reverse index identifies this exact wrapper. Recalled or superseded shells report both flags as false, even if the same external NFT is subsequently vaulted again; their provenance remains available.

**Recallability transition timeline (pending vs fully vaulted):**
- **Pending vault** (`_contractTokenAddresses != address(0)` and `!= address(this)`): NFT is deposited but not wrapped; depositor can cancel via `recallToken`; recallability flag is not the gate here.
- **Fully vaulted + not recallable** (`_contractTokenAddresses == address(this)` and `recallable == false`): wrapper exists, but recall is blocked.
- **Fully vaulted + recallable** (`_contractTokenAddresses == address(this)` and `recallable == true`): approved wrapper operator can execute recall.
- **After successful recall**: vault ownership mapping clears to unvaulted, `recallable` is cleared, and provenance fields on the Digil shell stay populated.
- **After inactive full discharge of wrapper**: attachment recallability is cleared even though provenance metadata remains for indexing.

 

---

## Distributions, Withdrawals & Reclaims

### Withdrawals
`withdraw()`

Call `withdraw()` to collect pending ETH and DIGIL. If your wallet rejects ETH, use `withdrawTo(address payable ethRecipient)` with a nonzero recipient. The caller keeps the DIGIL, collector yield, and opt-out rules. If the ETH recipient rejects payment, the transaction reverts and the credits remain available.
- **Time Bonuses (Checkpoint-Based)**: If you hold Digils, each full 15-minute interval (`BONUS_INTERVAL`) since your last checkpoint adds 1% of your checkpoint cap, where `checkpoint cap = scaled coin rate + (balance * _coinMultiplier / YIELD_PERIOD)`. Accrual saturates at that checkpoint cap, then stops until the next checkpoint.
- **Timer Reset Semantics**: Both withdrawal methods and qualifying ERC-721 balance updates both checkpoint yield. At each checkpoint, the timer resets to the current timestamp, so partial intervals are discarded and never carried forward.
- Both withdrawal methods settle the same pending ETH and DIGIL from charging, activation, discharge, and keeper rewards.
- **Best-Effort Coin Payout**: Coin transfer is best-effort. If mint/transfer of DIGIL fails in the ERC20 path, `withdraw()` does not revert for that reason and can return `0` coins while still paying ETH.

### Known Operational Caveats

- **Refund liquidity**: Refunds and rewards share the contract’s DIGIL balance. If the balance is short and minting is unavailable, the DIGIL credit remains pending. Anyone can replenish the balance. The role administrator can restore minting within the supply cap, and transfers must be enabled for payout.
- **Operator UX implication**: frontends/indexers should treat `(coins == 0, value > 0)` from `withdraw()` as a possible soft coin-payout failure rather than assuming no pending coin entitlement existed.
- **Retry behavior**: users can call `withdraw()` again later when DIGIL transfer conditions recover; this does not require replaying prior lifecycle operations.


**Example (inside vs. outside one interval):**
- Suppose your checkpoint cap is **500 DIGIL** and your last checkpoint was just set.
- If you call `withdraw()` again after **10 minutes** (< 15 minutes), bonus from that call is **0** and the timer resets at that call.
- If you then wait **20 minutes** and call `withdraw()` again, exactly **1** full interval has elapsed, so bonus is **1% of 500 = 5 DIGIL** (well below the 500 DIGIL checkpoint cap).

### Contributor Reclaim
`reclaimContribution(uint256 tokenId)`

A conditional inactivity exit. If you contributed to an inactive token that has had no meaningful activity for 90 days and is not in a batch, you can reclaim your recorded ETH after paying the existing reclaim penalty, forfeiting associated Coins. Identical updates, redundant whitelist entries, self-transfers, and zero-value enrichment do not restart the clock. Genuine changes to ownership, parameters, metadata, restrictions, funding, charging, or lifecycle do restart it. This is token inactivity, not contribution age: genuine activity can postpone reclaim indefinitely.

---

## Opt-Out / Blacklist

`setOptStatus(bool optOut)`

Accounts can willingly blacklist themselves via this function by paying a small fee. Blacklisted accounts cannot send/receive Digils, participate in charging, or withdraw pending Coins while opted out. They can, however, always withdraw their pending ETH. Opting out does not itself reset any already-accumulated pending Coin bonus timing state. This is useful for individuals who wish to permanently exit the gameplay loop.
- **Event Surface**: Opt state transitions emit `OptStatus(address account, bool optOut)` for both opt-in and opt-out transitions.
- **Transfer Lock While Opted Out**: Opted-out accounts cannot transfer their Digils until they opt back in by paying the opt-in fee.
- **Approvals Are Not Retroactively Revoked**: Opt-out blocks direct actions by the opted-out account but does not invalidate previously granted ERC-721 operator approvals; approved operators can still act where contract checks allow.

---

## Admin & Security Notes

- **Metadata Updates**: `updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes data, string uri)`  
  Token URIs and internal arbitrary data can be updated by paying the required Coin cost. When `uri` and `data` are both empty, `msg.value` must equal exactly `0`. When either `uri` or `data` is non-empty, `msg.value` must equal exactly `max(currentIncrementalValue, newIncrementalValue, globalIncrementalValue)`. Required ETH from this call is routed into the protocol value pool. Economic parameters are frozen only while the token currently has pending inactive `charge > 0`; if current charge is zero, they may be changed even if the token was used in an earlier lifecycle.
- **Restriction Controls**: Restriction management allows approved operators to manage a token’s restricted/open mode and contributor allowlist with explicit on-chain events. Switching from open to restricted mode may require ETH (`max(token.incrementalValue, globalIncrementalValue)`), while allowlist additions/removals do **not** charge DIGIL coin transfers.
- **Whitelist Directionality**: In the current implementation, whitelist flags are one-way at storage level: once an address is marked whitelisted for a token, that mapping entry is not cleared by later `restrictToken` calls.
- **Owner Auto-Whitelist on Transfer**: On mint/transfer, the recipient is automatically marked whitelisted for that token in the internal contributor mapping. This is intentional and persists across epochs.
- **Planar Custody Model**: Planar tokens are protocol/admin artifacts, not user-sovereign collectibles. Admin may recover or enforce custody of planar tokens consistent with current contract ownership. Integrators should treat planar token possession as non-final custody unless they also control contract ownership/governance.
- **Read-Only Views**: The contract exposes various functions to allow front-ends to easily read the complex, packed state of any Digil:
  - `tokenURI(uint256 tokenId)`
  - `tokenCharge(uint256 tokenId)`
  - `tokenData(uint256 tokenId)`
  - `tokenBuff(uint256 tokenId)`
  - `tokenContribution(uint256 tokenId, address contributor)`
  - `tokenLinkAt(uint256 tokenId, uint256 index)`
  - `tokenAttachment(uint256 tokenId)`
- **Lifecycle/Event ABI Notes**:
  - Batch lifecycle continuation emits `Batch(uint256 tokenId)` while activation/discharge are in progress.
  - Priming, stabilization, and temporary buff changes emit `Buff(uint256 tokenId)`; consumers should query `tokenBuff(uint256 tokenId)` to interpret the active buff state.
- **Batch Safety**: Sensitive lifecycle transitions are protected by batch-locks. If a token is mid-activation, it cannot be transferred, charged, or updated until the community finishes the batch processing.

---

## Economics & Costs Summary

- **Operations costing ETH**: Token creation (at least the global incremental value, or more for some restricted tokens), proxy-charging, establishing new links, updating metadata, overcharging, reclaiming abandoned contributions, and switching a token from open mode into restricted mode.
- **Discharge ETH bootstrap (first-call only)**:
  - `dischargeToken` first call (inactive or active path) requires exact ETH:
    - `msg.value == max(token.incrementalValue, globalIncrementalValue) * max(links.length, 1)`.
  - Continuation discharge calls require `msg.value == 0`.
  - So, inactive discharge does **not** require any extra active-only ETH bootstrap; it uses the same first-call formula as active discharge.
- **Creation ETH floor logic**:
  - Base minimum: `msg.value >= globalIncrementalValue`.
  - Restricted token override: if `restricted == true` and `incrementalValue > globalIncrementalValue`, then `msg.value >= incrementalValue`.
  - Unrestricted token behavior: higher per-token `incrementalValue` does not increase the creation minimum, but it can increase ETH required in later charge flows.
- **Link ETH requirement formula**: For `linkToken(source, destination, efficiency)`, minimum ETH is:
  - `source.incrementalValue + destination.incrementalValue`.
  - Sent ETH is split between the two linked tokens (`floor(value/2)` to source, remainder to destination).
- **Operations costing Coins (DIGIL)**: Paid plane alignment, metadata updates, linking/upgrades, priming, stabilizing, and vaulting external NFTs. These nonrefundable fees earn donor-reward points when the spender weight is enabled. Temporary buffs consume active charge rather than transferring DIGIL. Restriction-list updates do not trigger DIGIL coin transfers.
- **Operations that are free (gas only)**: Activating, Deactivating, unlinking, and standard internal transfers.

*(Note: Exact values fluctuate based on the `configure` dials managed by the Digil Governor).*

---

## Local Validation

### Run the Full Suite

The full suite runs in **Node.js 24**, not in Remix's JavaScript console or Solidity Unit Testing plugin. It creates disposable EthereumJS VMs, advances simulated time for long-duration checks, and needs no wallet, private key, live network, Codex, or running Remix session. It does not change your Remix VM deployment.

Install Node.js 24 with npm if needed, then open a normal **PowerShell/Windows Terminal** window. Remix Desktop's native system terminal can also be used; do not paste these shell commands into its JavaScript console. Run each command below, stopping if one fails:

```powershell
Set-Location 'C:\Users\gSOLO\Documents\GitHub\DigilCoin'
node --version
npm --version
npm ci
npm run check:size
npm test
```

Adjust the directory if your checkout is elsewhere. `node --version` should show `v24.x`. `npm ci` installs the versions in `package-lock.json`; rerun it on a fresh checkout or after the lockfile changes. The first installation needs internet access, but the tests themselves run locally. If PowerShell blocks `npm.ps1`, use `npm.cmd` in place of `npm` rather than weakening your execution policy.

`npm test` runs all five groups in order and exits nonzero if any group fails, even if later groups pass. Check `$LASTEXITCODE` immediately afterward (`0` means success). The output distinguishes behavioral assertions from setup/hooks and ends with an ABI exercise inventory. At the documented baseline, the groups contain 35 security scenarios, 72 Solidity behavioral calls plus 77 setup/hooks, 14 shared functional scenarios, 14 extended scenarios, and deployment-adapter checks including all 14 shared scenarios under both ethers versions. Counts will grow as tests are added; they are not a measure of exhaustive coverage.

### Individual Commands

| Command | Scope |
| --- | --- |
| `npm run check:size` | Compile all production contracts with the unchanged profile and check artifact sizes. |
| `npm test` | All five test groups plus the combined ABI exercise inventory. |
| `npm run test:security` | Accounting, permissions, lifecycle, interface, metadata-size and arithmetic-bound regressions. |
| `npm run test:remix` | Run `tests/*_test.sol` in Node with Remix-style annotations, hooks and assertions. This is not the Desktop smoke script. |
| `npm run test:functional` | Run the shared 14-scenario registry directly in Node. |
| `npm run test:extended` | Signatures, epoch/lock/timelock boundaries, malicious receivers and governance rehearsal. |
| `npm run test:deployment` | Exercise the real Remix workflow through the local plugin/RPC adapter under ethers v5 and v6. |
| `npm run format:scripts` | Format only JavaScript/CommonJS files under `scripts/`. |
| `npm run format:scripts:check` | Check script formatting without writing files; fail if formatting differs. |

All runners read the compiler profile directly from `remix.config.json`, without changing optimizer settings or enabling via-IR. Tests use Osaka's 16,777,216 transaction gas limit. The legacy Alpha, Beta, Foxtrot, and Gamma Solidity harnesses still exceed the runtime size limit and are Node-only test scaffolding; only those test deployments may use a size exemption. All production deployments, the new actors, shared functional scenarios, and deployment-adapter checks enforce normal code and initcode limits. Legacy harness success is not production deployment evidence.

`npm run test:security` runs targeted accounting, permission, lifecycle, and interface regressions. `npm run test:remix` runs the existing Solidity suites with fixture addresses substituted in memory, leaving `DigilTestLibrary.sol` unchanged. For diagnosing behavior while a contract exceeds deployment size, `node scripts/security-tests.cjs --diagnostic` and `node scripts/remix-tests.cjs --diagnostic` explicitly waive code-size limits, but never the transaction gas limit. Passing diagnostic runs is **not** deployment approval; the normal size gate must pass before release.

`npm run test:functional` runs the 14 shared scenarios. `npm run test:extended` adds typed signatures, epoch/lock/timelock and collector-yield boundaries, failed and reentrant receivers, ERC20 payout failures, and pre/post-revocation governance execution. `npm run test:deployment` checks the actual Remix workflow through a local plugin adapter using ethers v5 and v6, including browser structured-clone boundaries, compiler-event input validation, interruption/resume, repeated seeding, stale records, role drift, no-op clock detection, and deliberately failing assertions. `npm test` runs all five groups and reports failures with a nonzero exit code.

The `ethers-v5` development-only alias tests compatibility with Remix's default dependency; it must not be used with real keys. The runner uses it only for ABI encoding/decoding and hashing, never wallet signing or an external provider. Pinned `ws` and `tmp` overrides address transitive high-severity advisories without changing Solidity or its settings. `npm audit` still reports low-severity advisories in the v5/elliptic dependency chain; compatibility testing is not an endorsement of that chain for production signing.

Solidity suites retain source order, honor sender/value annotations and all four lifecycle hooks, count setup separately, and use isolated protocol state between suites. The end-of-run ABI inventory maps exercised entry points to scenario names in ignored `.remix/coverage/inventory.json` and explicitly lists unexercised functions. It includes negative calls and is not branch coverage. Current invariants include fee-versus-principal separation, reward-pool conservation, atomic rollback, market-outcome immutability, preserved lock principal, one-time payouts, NFT custody, and a deterministic 48-action ERC20 supply/balance model (seed `0xD1611`). It does not exhaustively model randomized NFT/link/market interactions, every malicious dependency, or every branch of inherited OpenZeppelin functions. Passing tests do not establish absence of vulnerabilities.

DigilToken's size optimizations preserve its public ABI and protocol behavior. Dynamic bytes/string arguments use memory to share compiler-generated decoding and storage-copy routines; whitelist arrays remain in calldata. This trades some copying gas for smaller bytecode. Arithmetic-check reductions are limited to documented bounds and guarded subtractions. Regression tests cover metadata storage-word boundaries through 4,096 bytes, maximum link efficiency/count, buff expiry, and exact batch endpoints. Deployment headroom is tight, so rerun the normal size gate after every contract change.

Deployment bootstrap remains: deploy DigilCoin, deploy DigilToken with that coin and 18 decimals, then grant the token `MINTER_ROLE` on DigilCoin and set its spend weight to `10000`. Minting permission enables rewards payouts; spend weight separately enables donor-reward eligibility for fees. These changes target fresh deployments, not migration of live contract storage.

## Test Coverage

### Which Tests Run Automatically?

**`npm test` already runs `DigilTokenA_test.sol` and all the other `tests/*_test.sol` suites. No separate manual run is needed for full local validation.** Run `npm run test:remix` to execute just those Solidity suites in Node. Despite its name, that command does not open Remix or use your existing Remix deployment.

There are two different Remix-related workflows:

| Invocation | What actually runs |
| --- | --- |
| `npm test` in a system terminal | Security, legacy Solidity, shared functional, extended, and deployment-adapter groups, in that order. |
| `npm run test:remix` in a system terminal | All 13 top-level `tests/*_test.sol` files: DigilCoin, DigilToken A-K, and the runner-hook self-test. |
| **Run Script** on `scripts/remix/test.js` in Remix | Only the 14 shared JavaScript smoke scenarios, or the IDs selected by `only`. It does **not** discover or run `tests/*.sol`. |
| Remix's Solidity Unit Testing plugin | A separate manual compatibility workflow for the Solidity files you select; not required in addition to `npm test`. It needs the helper addresses/bootstrap described in the repository guidance, and the oversized harness limitation below still applies. |

Solidity discovery is **not recursive**: a new suite must be directly inside `tests/`, end in `_test.sol`, and contain exactly one suite contract for the Node runner. Test functions must be public/external, take no arguments, and start with `test`; the four lifecycle hook names are recognized separately. Tests retain source order and shared state **within** each suite, with protocol state isolated **between** suites. Sender/value annotations are honored, and fixture addresses are substituted in memory rather than edited on disk. Hooks and methods beginning `testPrepare` or `testChargeBatch` are counted as setup, not behavioral calls.

`tests/SecurityActors.sol` supplies adversarial fixtures, `tests/RunnerFailureProbe.sol` supplies deliberately failing runner checks, and `tests/remix_tests.sol` / `tests/remix_accounts.sol` supply harness support. They are not independent auto-discovered suites. The failure probes are expected to fail internally; the adapter suite passes only when it detects their failures correctly. There is no separate `DigilGovernor_test.sol`: governance coverage currently lives in the JavaScript groups.

### Legacy Inventory and Independent Equivalents

Baseline: September 29, 2026. Counts below are **executed test methods**, not individual assertions. The 72 behavioral calls include two runner self-tests; 77 additional calls are setup/hooks. Every DigilToken suite also contains a `testWithdrawl` payout sequence. Those repeated checks still run, but should not be counted as eleven distinct feature areas.

The last column identifies existing JavaScript overlap and the assertions still worth porting. **Overlap is not a claim of complete replacement.** Keep the Solidity suites enabled for compatibility while adding independent cases.

| Solidity suite | Behavioral / setup calls | Existing coverage | Newer overlap and remaining replication work |
| --- | --- | --- | --- |
| `tests/DigilCoin_test.sol` | 5 / 1 | Initial metadata/supply, internal mint, allowances and transfers. | `deployment-bootstrap`, `erc20-allowance-burn-pause`, `roles-and-configuration`, and `seeded-erc20-conservation` cover the public behaviors with stronger permission/conservation checks. The inherited harness's internal `_mint` is not a public-API test. |
| `tests/DigilTokenA_test.sol` | 8 / 1 | Creation defaults, direct/sponsored charge, ETH floor/excess, discharge, activation and restrictions. | Functional lifecycle/refund cases and security settlement cases overlap. Port the exact initial-field, incremental-value and contributor accounting assertions as isolated scenarios. |
| `tests/DigilTokenB_test.sol` | 7 / 8 | Multi-batch activation, four-plane charge routing, invalid charges and upgrades at ten links. | Security tests independently cover exact batch endpoints and maximum link count/efficiency. Port the full mixed-plane routing sequence and its per-destination charge/value assertions. |
| `tests/DigilTokenC_test.sol` | 3 / 1 | Metadata/config updates, overpayment/charged-token rejection, and read-only `IDigilToken` fields. | Payload-boundary and interface-signature tests overlap. Port the complete fresh-token getter tuple/default URI checks and exact update failure cases. |
| `tests/DigilTokenD_test.sol` | 10 / 23 | 1,050 sponsored contributors, discharge continuation and final epoch/charge/value reset. | JavaScript covers 768 contributors at the recommended 256 per batch, plus keeper payouts, authorization and rounding. The full 1,050-contributor sequence still runs in Solidity. |
| `tests/DigilTokenE_test.sol` | 7 / 1 | Restricted links/unlinking, opt-out and re-entry, deactivation, and three link ETH pricing/split combinations. | NFT transfer/whitelist and link arithmetic cases overlap. Extended tests cover withdrawal opt-out and re-entry. Port the complete restricted-routing/ETH-split matrix. |
| `tests/DigilTokenF_test.sol` | 7 / 10 | Multi-batch activation, unequal affinity-weighted discharge to four destinations, and deactivation loss. | Security covers equal-weight ten-link discharge; functional tests cover deactivation state. Port the unequal distribution amounts and exact active-charge loss. |
| `tests/DigilTokenG_test.sol` | 4 / 1 | Planar link base/affinity values, sponsored contributor records and contribution epoch reuse. | Affinity arithmetic and sponsored-principal regressions overlap. Port the complete contributor-field and deactivate/recharge epoch sequence. |
| `tests/DigilTokenH_test.sol` | 5 / 8 | Multi-batch activation, buff cost and buffed charge routing across four planes. | Buff bounds/expiry and affinity persistence are independently tested. Port the mixed-plane buffed routing amounts. |
| `tests/DigilTokenI_test.sol` | 5 / 8 | Buff, deactivate/reactivate, overcharge, stabilization and later discharge charge-loss sequence. | Feature-fee and buff-bound tests overlap, but do not reproduce all intermediate balances in this sequence. |
| `tests/DigilTokenJ_test.sol` | 4 / 1 | Priming, multi-field buffs/flags/appearance, link upgrades and exact amplification cost/gain. | JavaScript checks prime fees, buff bounds and permanent affinity; it does not yet independently reproduce the priming/amplification and combined-flag assertions. |
| `tests/DigilTokenK_test.sol` | 5 / 8 | Buff/stabilization lifecycle and reverberated source/destination charge accounting. | Fee/expiry tests overlap; the complete reverberation and lifecycle balance sequence still needs a JavaScript equivalent. |
| `tests/RunnerHooks_test.sol` | 2 / 6 | Hook ordering, sender/value annotations and boolean test returns. | Adapter tests also check rejection of false assertion events, false returns and EVM failures. This is runner validation, not protocol coverage. |

Alpha (A), Beta (B), Foxtrot (F), and Gamma (G) are oversized **test harnesses**. The Node runner narrowly exempts those harness deployments, not DigilCoin, DigilToken, DigilGovernor or DigilTimelock. Their successful execution does not mean those harnesses can be deployed in the normal Remix VM. Do not disable production size limits or change compiler settings to run them manually.

### Shared Smoke Scenarios

These exact IDs live in `scripts/functional-scenarios.js`. All run directly in Node and through the deployment adapter under ethers v5 and v6; `scripts/remix/test.js` runs the same registry in Remix. Repetition across adapters validates portability, not additional distinct protocol behavior.

| Scenario ID | Assertions covered |
| --- | --- |
| `deployment-bootstrap` | Initial metadata/supply, 21 planar owners, roles, spend weight, governance wiring/defaults, interfaces, and rejection of zero-owner/EOA-coin token deployments. |
| `roles-and-configuration` | Unauthorized configuration/mint/pause calls, parameter bounds, ownership and role changes. |
| `public-configuration-and-receiver-policies` | Constants, role administration, EIP-712 domains, Governor metadata and ERC721/ERC1155 receiver policies. |
| `erc20-allowance-burn-pause` | Finite/infinite allowances, delegated transfer/burn, supply accounting and paused operations. |
| `delegation-and-checkpoints` | Delegation, vote changes, checkpoint creation and future-query rejection. |
| `paid-fees-versus-deposits` | Metadata fees earn points; charge principal and ordinary transfers do not; zero spend weight disables points. |
| `metadata-payload-boundaries` | Create/update payloads of 0, 1, 31, 32, 33, 1,024 and 4,096 bytes, URI updates and unauthorized-update rejection. |
| `nft-approval-transfer-restrictions` | Owner/operator approvals, both safe-transfer overloads, cleared approvals and persistent recipient auto-whitelisting. |
| `ownership-renunciation-is-explicit-and-final` | Unauthorized renunciation rejection and loss of former-owner administrative authority. |
| `inactive-refund-and-activation` | Sponsored contribution, activation/discharge authorization, principal refund, active charging and deactivation. |
| `vault-payload-recall-and-rewrap` | Pending custody/recall/redeposit, authorized wrapping, payload boundaries, activation-gated recall and cleared custody. |
| `missing-minter-and-best-effort-retry` | Failed reward mint preserves entitlement; restoring the role permits a single payout. |
| `governor-unauthorized-entry-points` | Unauthorized governance configuration/relay, unknown proposals, invalid voting/locking/staking/claiming and timelock scheduling. These are negative cases, not successful governance execution. |
| `seeded-erc20-conservation` | A deterministic 48-action transfer/burn model checks balances and total supply using seed `0xD1611`. |

### Security, Extended and Deployment Coverage

| Area | Existing checks and location |
| --- | --- |
| Fee and reward accounting | `security-tests.cjs`: weighted fee attribution including paid alignment; no rewards for refundable/sponsored/active principal; daily caps, rollover across the 2106 timestamp boundary, long-idle synchronization, claims/replay, paid welcome eligibility and failed-creation rollback. `extended-tests.cjs`: active-day boundaries, parameter snapshots, atomic `claimMany`, ETH conservation and forced-ETH synchronization. |
| NFT lifecycle and settlement | `security-tests.cjs`: stale-wrapper custody, genuine versus no-op inactivity resets, metadata boundaries, permanent affinity, maximum efficiency/ten links, exact buff expiry, payout rate snapshots, keeper fee allocation, direct-deposit activation rewards, rounding, authorization and batch endpoints. Legacy suites add the larger and mixed-mechanic sequences above. |
| Voting and markets | `security-tests.cjs`: early cancellation refunds, immutable late outcomes, orphan burns, preserved lock principal, deadline/quorum/replay/bounds. `extended-tests.cjs`: permit/delegation/ballot signatures, nonce/domain/expiry checks, historical votes, NFT reuse/operator checks, lock extension/rollback/unlock boundaries. |
| External-call failures | `extended-tests.cjs`: failed/reentrant ETH withdrawals and claims, ERC721 receiver rejection with approval/custody rollback, and false-returning ERC20 payout retry without duplicate entitlement. Collector-yield interval, saturation and transfer boundaries are also tested there. |
| Timelock and governance handoff | `extended-tests.cjs`: delay/predecessor/cancellation/role revocation, and real proposal/vote/queue/execute sequences before and after bootstrap roles are removed. This is a disposable **Node rehearsal**, not an approved handoff of a user's Remix deployment. |
| Deployment and tooling | `remix-runtime-tests.cjs`: actual workflow modules through simulated Remix plugin/RPC boundaries; ethers v5/v6, compiler/source freshness, structured-clone safety, VM-only guards, code/constructor size checks, deployment verification, interrupted deployment/resume, idempotent seeding, stale journals/VM reset, role drift and handoff blocking. Negative-call checks reject transport failures, out-of-gas and invalid-opcode failures as substitutes for a proven revert. |

The deployment adapter is local integration testing, not browser/desktop UI automation. The maintainer-confirmed Desktop result is the 14-case smoke subset. Production contracts are actually deployed under normal limits by the Node fixtures; deployment size checks alone do not prove every constructor validation branch, network environment or operator workflow.

### What the Coverage Numbers Mean

The full suite exercises **194/194** ABI function signatures across DigilCoin **64/64**, DigilToken **45/45**, DigilGovernor **57/57**, and DigilTimelock **28/28**. The JavaScript suites also reach all 194 independently. The legacy suites retain distinct behavioral assertions, as listed above.

`scripts/test-all.cjs` combines `.remix/coverage/{security-tests,remix-tests,functional-tests,extended-tests}.cjs.json` into ignored `.remix/coverage/inventory.json`. The deployment-adapter runs are not added to that inventory. Records must share the current run ID; missing/stale records or failed suites cause failure. `calls` maps each signature to scenario names and `unexercised` lists missing signatures. Run **`npm test`** to refresh the combined file; an individual runner updates only its own file.

This is execution tracking, **not statement, branch, path, assertion or mutation coverage**. Negative calls and nested calls count; a getter or unauthorized call can exercise an entry point without testing its successful behavior. Constructors, receive/fallback handling, event payloads and internal functions are not measured as separate ABI function signatures. There is currently **no coverage-percentage gate**: unexercised signatures are reported but do not by themselves fail `npm test`. No defensible percentage of all protocol behavior is currently available.

### Missing and Incomplete Tests

These are test gaps, not findings that the contracts are necessarily defective. Existing overlapping coverage is identified so that adding tests does not accidentally remove protections already supplied by the legacy suites.

| Priority | Gap | Concrete additional checks |
| --- | --- | --- |
| High | Independent legacy parity | Extend opt-out coverage to owners, recipients, sponsored contributors and approved operators across other lifecycle operations. Port mixed-plane routing, link ETH splits, unequal discharge weights, amplification/flags, stabilization/reverberation and the large-contributor case from the table above. Keep the original Solidity tests running. |
| High | Epoch sweep and long-idle accounting | Existing cases cover claims, stale user records at 12-slot reuse and long-idle jumps. Model unclaimed funds across the 3-epoch claim window, empty and partially claimed pools, and the 15/16-step rollover boundary with donations, rounding and repeated syncs. |
| High | Stateful multi-contract invariants | Add multiple reproducible seeds and randomized NFT/link/charge/activate/discharge/vault/transfer sequences, checking principal, custody and one-time payout invariants after every action. Add overlapping governance markets plus locks, varied claim order and rounding dust. The current seeded model covers ERC20 transfers/burns only. |
| Medium | Complete authorization and failure matrix | Expand owner/operator/third-party cases across opt-out, restrictions and in-progress batches; assert exact custom errors and unchanged balances/flags after failures. Many legacy `try/catch` checks accept any revert, and Node `h.reverts` without an error name accepts execution failures more broadly than the Remix adapter. |
| Medium | Broader hostile dependencies and callbacks | Add malicious ERC721 collection callbacks, ERC20 transfer/mint failure variants and callback attempts during other settlement paths. Existing receiver/reentrancy actors cover specific withdrawal, claim, payout and transfer cases, not every external-call path. |
| Medium | Deployment and runner matrices | Expand invalid constructor/configuration combinations and interruption points, maintain repeatable Desktop smoke validation for supported Remix versions, and add gas-regression budgets at configured batch limits. Size and per-transaction gas limits are already enforced; wallet-backed/live-network deployment remains intentionally out of scope. |
| Medium | Coverage quality and automated enforcement | Add statement/branch measurement in a separate diagnostic setup without changing the production compiler profile, mutation checks for key accounting assertions, and an explicit coverage-regression gate. Add CI invocation of size/full-suite/format checks; no checked-in CI workflow currently runs these commands automatically on commits. |

For independent replicas, use one fresh fixture per scenario and reference the originating `File_test.sol.testMethod` in a short source comment. Preserve each meaningful expected balance, field and lifecycle transition, then add boundary, unauthorized, rollback and repeated-call checks. Use `scripts/functional-scenarios.js` for portable cases and the Node security/extended registries for time-dependent, high-volume or adversarial cases; see [Script Maintenance](#script-maintenance). A port is complete when its assertions stand alone without relying on an earlier legacy method, not merely when it calls the same functions. This documentation inventories the remaining work; it does not add or disable test cases.

## Script Maintenance

### Where to Make Changes

| File(s) | Responsibility and extension point |
| --- | --- |
| `scripts/compile.cjs` | Pinned compiler/import resolution and production size gate. Treat compiler settings as read-only. |
| `scripts/evm.cjs` | Node-only VM, deterministic accounts, time, deployments and ABI exercise records. |
| `scripts/test-all.cjs` | Launch the five runners and combine only their current-run inventory files. Register a new Node group here and in `package.json` if one is genuinely needed. |
| `scripts/security-tests.cjs` | Add targeted security regressions to its local `test(name, run)` registry. Each case restores the common funded fixture. |
| `scripts/extended-tests.cjs` | Add time-sensitive, signature, malicious-actor or governance cases to its registry. Each case receives a fresh four-contract fixture. |
| `scripts/functional-scenarios.js` | Add portable scenarios here to run them in both Node and Remix Desktop. |
| `scripts/functional-tests.cjs` | Node runner and shared four-contract bootstrap for functional/extended cases. |
| `scripts/remix-tests.cjs`, `scripts/solidity-suite.cjs` | Discover and run Solidity suites, preserve source order, honor hooks/annotations and decode assertion failures. Add protocol cases to `tests/*_test.sol`; keep one suite per file. |
| `scripts/remix-runtime-tests.cjs` | Regression tests for the actual Remix runtime/dispatcher. Model real messaging/RPC quirks here whenever a Desktop integration bug is fixed. |
| `scripts/remix/runtime.js` | Remix compiler validation, guarded VM RPC, receipt/revert proof, role checks and deployment journal. |
| `scripts/remix/workflow.js` | Dispatch the six user-facing workflows. Keep protocol assertions in the scenario registry and provider-specific operations in the runtime. |
| `scripts/remix/preflight.js`, `test.js`, `deploy.js`, `verify.js`, `seed-demo.js`, `handoff.js` | Thin **Run Script** entry points in the same directory; their effects and success conditions are listed below. |

The `.cjs` files use Node's CommonJS module system and may access the filesystem. The shared `.js` scenarios and Remix modules must stay browser-compatible: no Node-only imports, filesystem access, signing keys or external providers. Remix loads the checked-in modules through `fileManager`; run the entry-point files, not `runtime.js`, `workflow.js` or the scenario registry directly.

### Add a Portable Scenario

Add a unique `test('your-scenario-id', async (...) => { ... })` inside `scenarios()` in `scripts/functional-scenarios.js`, before `return tests`. For example:

```js
test('mint-permission-example', async ({ h, coin }) => {
  const [admin, alice, bob] = h.users;
  const amount = 10n * UNIT;

  await h.send(coin, admin, 'mint', [alice.address, amount]);
  eq((await h.read(coin, 'balanceOf', [alice.address]))[0], amount);

  await h.reverts(
    coin,
    bob,
    'mint',
    [alice.address, amount],
    0n,
    'AccessControlUnauthorizedAccount'
  );
  eq((await h.read(coin, 'balanceOf', [alice.address]))[0], amount);
});
```

This example illustrates the pattern; the registry already tests mint permissions. Add assertions for both the intended state change and relevant failure/rollback behavior. Use `bigint` for amounts and decoded integers, `UNIT` for DIGIL units, and `FLOOR` for the existing ETH floor. Await every chain operation. Do not depend on another scenario's deployments or balances: each scenario gets `{ h, coin, token, governor, timelock }` with a fresh fixture.

| Shared helper | Contract |
| --- | --- |
| `h.users` | Test accounts; `[admin, alice, bob, ...]` expose `.address`. Never use Node signing keys in a portable scenario. |
| `h.send(contract, user, method, args = [], value = 0n)` | Send a successful transaction; throws on failure. Keep the returned result opaque and pass it to `h.events`. |
| `h.read(contract, method, args = [], caller?)` | Read a decoded result array. Use `[0]` for a single return value and explicit callers when access matters. |
| `h.events(contract, result, eventName)` | Decode matching events from a send result. Indexed argument access works in both adapters. |
| `h.reverts(contract, user, method, args = [], value = 0n, errorName?)` | Require execution failure; optionally assert a specific custom error. Remix additionally checks failed receipts and the recorded REVERT. |
| `h.deploy(name, args = [])` | Deploy an available artifact. Portable tests currently have the four protocol contracts and `NFT`; adding another requires registering its source in both compilation paths. |
| `h.id(text)`, `h.encode(types, values)` | Hash signatures/role names and ABI-encode values without coupling to ethers v5 or v6. |
| `eq(actual, expected)`, `ok(condition, message?)` | Strict assertions exported by the scenario module. A failed assertion must escape to the runner. |

When adding or removing shared scenarios, update the expected `smoke.results.length` assertion in `scripts/remix-runtime-tests.cjs` and the documented smoke counts. Both runners discover cases from the registry automatically, but the adapter's count assertion deliberately catches omitted cases.

Test the addition with `npm run test:functional` and `npm run test:deployment`, then run `npm test`. In Remix, set `only` in `scripts/remix/test.js` to the new ID while iterating; restore `[]` for the complete smoke registry. Put clock-dependent, snapshot-dependent, private-key/signature or adversarial-actor cases in the Node-only suites, not the shared registry. Never weaken provider guards, deployment limits, named-error assertions, receipt evidence or governance-handoff blocking to make a test pass.

### Formatting and Artifacts

The pinned Prettier development dependency uses the scripts-only override in `.prettierrc.json`: two spaces, single quotes and a 100-column print width. Run `npm run format:scripts` after editing and `npm run format:scripts:check` before committing. These commands do not format Solidity, change compiler settings, or touch dependency caches. See the [Prettier CLI](https://prettier.io/docs/cli) for formatter behavior.

Keep reusable behavior notes near the relevant helper; use module headers to identify environment and invocation. Prefer focused scenarios over adding another runner. The ignored `.remix/Compile.sol`, `smoke-results.json`, `deployment.json` and `coverage/` files are generated state, not source files to edit or commit. Preserve deployment journals when diagnosing interrupted transactions. To investigate a failed run, read the first named `FAIL` line and its error rather than treating the final count as the cause.

## Remix VM Deployment and Tests

The scripts in `scripts/remix/` automate a **local Remix VM only**. They refuse wallet providers, external RPCs, and forked VMs. No Codex or Node installation is needed to invoke these scripts inside Remix.

The workflow targets Remix **2.6.4**, Solidity **0.8.39+commit.ce47f2c8**, and **Remix VM (Osaka)**. The Node integration tests exercise this compiler through the Remix plugin/RPC adapter with ethers 5.8.0 and 6.17.0. The maintainer’s September 29, 2026 smoke run in Remix Desktop passed all 14 scenarios with Solidity 0.8.34.

### Compiler and Workspace Setup

1. Import this repository into a separate Remix workspace, including `contracts/`, `scripts/`, `remix.config.json`, and the pinned `.deps/npm/@openzeppelin/contracts@5.7.0/` cache. Keep the repository directory structure and dependency resolution index. Do not use historical `scenario.json` bytecode.
2. In **Solidity Compiler**, select **0.8.39+commit.ce47f2c8**. Under **Advanced Configuration**, select **Use configuration file** and choose the repository’s `remix.config.json`. The scripts check the complete `solidity-compiler` input, including Osaka, the optimizer detail flags with `yul: false`, and stripped revert strings. Leave `runs` and `viaIR` unspecified. [Remix compiler configuration](https://remix-ide.readthedocs.io/en/latest/compile.html)
3. In **Deploy & Run**, select **Remix VM (Osaka)** and use a fresh VM. Account 0 is the bootstrap admin; scripts select VM accounts explicitly, regardless of the displayed account dropdown. Keep at least five default VM accounts.
4. Open a script below and use **Run Script** (or right-click the file and choose **Run**). Use the default script dependency configuration, which supplies ethers v5; the adapter also supports v6. Approve only the expected Remix workspace-file, compiler, and local blockchain plugin requests. No wallet, private key, public-network access, or external signing permission is needed. See [Remix script execution](https://remix-ide.readthedocs.io/en/latest/running_js_scripts.html).
5. Run one script at a time. Do not change the workspace, sources, configuration, or VM provider while it is running.

Compiler validation reads the complete JSON input from the fresh `compilationFinished` event and compares it with the repository profile before allowing deployment. It does not request `getCompilerState`, whose callbacks cannot be cloned across Remix Desktop's script iframe boundary. The compiler version, dependency contents, and deployment-size checks remain enforced.

### Commands in Remix

| Script | Action and success condition |
| --- | --- |
| `scripts/remix/preflight.js` | Compiles fresh sources, checks settings/dependency bytes and deployment sizes, and probes time control. Expect `PASS deployment preflight` plus the explicit timing limitation. Deploys no production contracts. |
| `scripts/remix/test.js` | Runs 14 shared smoke scenarios, each with a fresh four-contract fixture. Expect `Remix smoke subset: 14 passed, 0 failed`. Writes the results and omitted areas to `.remix/smoke-results.json`; this is **not** full protocol validation. |
| `scripts/remix/deploy.js` | Creates or resumes the interactive deployment, grants required roles, checks code and role holders, prints addresses, and writes `.remix/deployment.json`. Expect `PASS deployment`. |
| `scripts/remix/verify.js` | Recompiles and verifies the recorded deployment against current sources, transaction history, runtime code, ownership, planar custody, spend weight, and roles. Expect `PASS current deployment verified`. |
| `scripts/remix/seed-demo.js` | Optional, explicit seeding: mints 20,000 DIGIL to each of accounts 1 and 2, delegates votes, approves DigilToken, and creates one NFT per account. Journaled reruns do not duplicate minting or NFTs. |
| `scripts/remix/handoff.js` | **Preview/blocker only.** Displays intended governance ownership and role changes, then fails with `Handoff blocked`. Sends no grants, transfers, or revocations. |

The deployment order is Coin, Token, Timelock, Governor. Token uses account 0 as owner, the new Coin address, and 18 decimals. It receives Coin `MINTER_ROLE` and spend weight `10000`. Timelock uses a **60-second VM-only delay**, empty initial proposer/executor lists, and account 0 as temporary admin; Governor receives proposer, canceller, and executor roles. Execution is not opened to the zero address. Ordinary deployment neither seeds users nor relinquishes admin control.

Use the printed addresses with **At Address** in Deploy & Run after selecting each compiled contract. The JS workflow never requires editing addresses in `DigilTestLibrary.sol`. Its test fixtures do not alter the interactive deployment record, though they consume transactions and create additional contracts in the selected VM.

Expected-revert assertions send transactions on these disposable VM fixtures, preserving the specified ETH value. They require a failed receipt and a simulator execution record showing `revert`, and decode the custom error when the scenario names one. Intentional failed transactions will appear in Remix during a passing test run. A successful transaction, out-of-gas, missing execution evidence, or RPC error is not accepted as a passing negative assertion. Remix's `eth_call` returns revert bytes without throwing and discards ETH value, so it is not used to prove these failures. See the official [Remix transaction RPC implementation](https://github.com/remix-project-org/remix-project/blob/master/libs/remix-simulator/src/methods/transactions.ts).

To rerun one smoke scenario, change only the `only` list in `scripts/remix/test.js`, for example:
```js
const only = ['metadata-payload-boundaries'];
```
Restore `[]` to run all 14. Available IDs are declared in `scripts/functional-scenarios.js`. An unknown ID or any failed assertion fails the run.

### Timing and Governance Handoff

Remix VM's current time-advance and snapshot RPCs are no-ops; mining uses wall-clock time. Preflight reads the resulting block timestamp rather than assuming those calls worked. See the official [VM RPC implementation](https://github.com/remix-project-org/remix-project/blob/master/libs/remix-simulator/src/methods/evm.ts). Fresh deployments isolate smoke scenarios without relying on snapshots.

The smoke subset omits the legacy Solidity suites, long-duration accounting and expiry tests, typed-signature scenarios, adversarial actors, and the complete governance rehearsal. Run **`npm test` for full local validation**. The [Solidity Unit Testing plugin](https://remix-ide.readthedocs.io/en/latest/unittesting.html) has a separate environment; it does not share the JS runner's Deploy & Run fixtures.

The Node rehearsal grants Timelock the Coin admin/operational roles, transfers Token ownership and all 21 planar tokens, completes a real propose/vote/queue/execute cycle, removes bootstrap privileges with timelock admin removed last, and completes another governance cycle. It verifies former-admin calls fail and Token mint-dependent payouts still work. Production voting delay and period stay unchanged. This rehearsal runs on disposable Node fixtures, **not your Remix deployment**, so it does not authorize automated revocation there. Remix handoff remains deliberately blocked until a genuine rehearsal on that deployment can be verified.

### Recovery and Failures

- **`postMessage` / function could not be cloned:** use the updated `scripts/remix/runtime.js` and `scripts/remix/workflow.js` from this checkout, then rerun `preflight.js`. Older versions requested Remix's non-serializable compiler state. Do not change compiler settings or reset the VM to work around this script integration error.
- **All smoke scenarios fail with `eth_getLogs` / reading `length`:** use the updated `scripts/remix/runtime.js` and rerun `test.js`. Remix requires an explicit `topics` array in the log query. The runner sends `topics: []` to retain all events and fully verify role grants and revocations; the old failure occurred during fixture setup, before the scenario assertions.
- **Four pass, ten fail with `... should revert`:** use the updated `scripts/remix/runtime.js` and rerun `test.js`. Older scripts expected `eth_call` to throw; Remix returns the revert bytes instead. The updated negative assertions verify failed transaction receipts and simulator execution records without relaxing authorization checks.
- **Wrong configuration, dependency, or artifact:** inspect the compiler error; restore the exact repository profile and pinned dependency sources, then rerun preflight. Do not change optimizer settings to pass a size check. Generated `.remix/Compile.sol` ties each run to a fresh compilation.
- **Interrupted deployment:** rerun `deploy.js` in the same VM/workspace. Confirmed steps are checked and reused; a saved pending hash is resumed. A broadcast without a saved hash is ambiguous and is refused. Inspect it manually or start with a fresh VM/workspace, rather than clearing the journal and creating duplicates.
- **Interrupted demo seeding:** rerun `seed-demo.js`, not `deploy.js`. Its saved pending step belongs to the seeding workflow. `verify.js` intentionally refuses any unresolved pending operation.
- **Reset VM or stale addresses:** old receipts/code invalidate the record even if the chain ID is unchanged. For a deliberately fresh deployment, reset the VM and use a new workspace, or archive the old `.remix/deployment.json` before rerunning deploy. Never reuse a record solely because its addresses look familiar.
- **Unexpected roles or ownership:** verification fails closed. Review the actual changes; do not weaken the verifier or remove roles blindly.
- **Failed assertion, RPC error, out-of-gas, or code-size failure:** stop and inspect the named scenario/transaction and compiler output. RPC disconnections are not accepted as expected EVM reverts. Transactions are capped at 16,777,216 gas; production runtime is limited to 24,576 bytes and creation input including arguments to 49,152 bytes.
- **Handoff blocked:** expected on the current VM. Retain bootstrap control. A green smoke run or a successful Node rehearsal is not permission to bypass this guard.

All runtime records and generated machine-readable test inventories live under ignored `.remix/`; keep them local. They contain test addresses and transaction evidence, not private keys.

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
