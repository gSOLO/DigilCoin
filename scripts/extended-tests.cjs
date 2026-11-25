/**
 * Node-only signature, time-boundary, adversarial-receiver and governance tests.
 * Each registered test receives a fresh fixture and may use h.time/test keys.
 * Command: npm run test:extended
 */
const assert = require('node:assert/strict');
const { compile, sourcesIn, checkSizes } = require('./compile.cjs');
const { createHarness, ethers, unit, floor, createAddressFromString } = require('./evm.cjs');
const { fullBootstrap } = require('./functional-tests.cjs');
const ZERO = ethers.ZeroAddress;

async function main() {
  const contracts = compile({
    ...sourcesIn('contracts'),
    ...sourcesIn('tests', (file) => file === 'SecurityActors.sol'),
  });
  checkSizes(contracts);
  const h = await createHarness(contracts);
  const [admin, alice, bob, carol] = h.users;
  const actor = () => h.deploy('CallbackActor', [], false, 'tests/SecurityActors.sol');
  const create = async (token, user = alice, threshold = 0n) =>
    h.result(
      token,
      'createToken',
      await h.send(token, user, 'createToken', [0, threshold, false, 0, '0x'], floor)
    )[0];
  const ethBalance = async (address) =>
    (await h.vm.stateManager.getAccount(createAddressFromString(address))).balance;
  const invoke = (receiver, target, method, args = [], value = 0n) =>
    h.send(
      receiver,
      admin,
      'execute',
      [target.address, target.iface.encodeFunctionData(method, args)],
      value
    );
  const tests = [];
  const test = (name, run) => tests.push({ name, run });

  test('Permit accepts a valid domain and rejects replay, expiry, wrong signer and wrong chain', async ({
    coin,
  }) => {
    const wallet = new ethers.Wallet(ethers.hexlify(alice.key));
    const domain = {
      name: 'Digil Coin',
      version: '1',
      chainId: 1,
      verifyingContract: coin.address,
    };
    const types = {
      Permit: [
        { name: 'owner', type: 'address' },
        { name: 'spender', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    };
    const message = {
      owner: alice.address,
      spender: bob.address,
      value: 77n * unit,
      nonce: 0,
      deadline: h.time + 1000n,
    };
    const permitArgs = (message, signature) => [
      message.owner,
      message.spender,
      message.value,
      message.deadline,
      signature.v,
      signature.r,
      signature.s,
    ];
    const signed = ethers.Signature.from(await wallet.signTypedData(domain, types, message));
    assert.equal(
      (await h.read(coin, 'DOMAIN_SEPARATOR'))[0],
      ethers.TypedDataEncoder.hashDomain(domain)
    );
    await h.send(coin, carol, 'permit', permitArgs(message, signed));
    assert.equal((await h.read(coin, 'nonces', [alice.address]))[0], 1n);
    assert.equal((await h.read(coin, 'allowance', [alice.address, bob.address]))[0], message.value);
    await h.reverts(coin, carol, 'permit', permitArgs(message, signed), 0n, 'ERC2612InvalidSigner');
    const next = { ...message, nonce: 1 };
    const wrongChain = ethers.Signature.from(
      await wallet.signTypedData({ ...domain, chainId: 2 }, types, next)
    );
    await h.reverts(
      coin,
      carol,
      'permit',
      permitArgs(next, wrongChain),
      0n,
      'ERC2612InvalidSigner'
    );
    const wrongSigner = ethers.Signature.from(
      await new ethers.Wallet(ethers.hexlify(bob.key)).signTypedData(domain, types, next)
    );
    await h.reverts(
      coin,
      carol,
      'permit',
      permitArgs(next, wrongSigner),
      0n,
      'ERC2612InvalidSigner'
    );
    const expired = { ...next, deadline: h.time - 1n };
    const expiredSig = ethers.Signature.from(await wallet.signTypedData(domain, types, expired));
    await h.reverts(
      coin,
      carol,
      'permit',
      permitArgs(expired, expiredSig),
      0n,
      'ERC2612ExpiredSignature'
    );
    assert.equal(
      (await h.read(coin, 'nonces', [alice.address]))[0],
      1n,
      'failed signatures cannot consume nonces'
    );
  });

  test('Delegation signatures share nonces and historical votes remain fixed', async ({ coin }) => {
    await h.send(coin, admin, 'mint', [alice.address, 100n * unit]);
    const wallet = new ethers.Wallet(ethers.hexlify(alice.key));
    const domain = {
      name: 'Digil Coin',
      version: '1',
      chainId: 1,
      verifyingContract: coin.address,
    };
    const types = {
      Delegation: [
        { name: 'delegatee', type: 'address' },
        { name: 'nonce', type: 'uint256' },
        { name: 'expiry', type: 'uint256' },
      ],
    };
    const message = { delegatee: bob.address, nonce: 0, expiry: h.time + 100n };
    const signature = ethers.Signature.from(await wallet.signTypedData(domain, types, message));
    const args = [bob.address, 0, message.expiry, signature.v, signature.r, signature.s];
    await h.send(coin, carol, 'delegateBySig', args);
    const snapshot = h.time;
    assert.equal((await h.read(coin, 'getVotes', [bob.address]))[0], 100n * unit);
    await h.send(coin, alice, 'transfer', [carol.address, 25n * unit]);
    assert.equal((await h.read(coin, 'getPastVotes', [bob.address, snapshot]))[0], 100n * unit);
    assert.equal((await h.read(coin, 'getPastTotalSupply', [snapshot]))[0], 100n * unit);
    assert.equal((await h.read(coin, 'getVotes', [bob.address]))[0], 75n * unit);
    await h.reverts(coin, carol, 'delegateBySig', args, 0n, 'InvalidAccountNonce');
    h.time = message.expiry;
    await h.reverts(coin, carol, 'delegateBySig', args, 0n, 'VotesExpiredSignature');
  });

  test('Signed ballots enforce the domain, nonce, NFT reuse and operator authorization', async ({
    coin,
    token,
    governor,
  }) => {
    for (const user of [alice, bob]) {
      await h.send(coin, admin, 'mint', [user.address, 20000n * unit]);
      await h.send(coin, user, 'delegate', [user.address]);
    }
    const aliceNft = await create(token, alice),
      carolNft = await create(token, carol);
    const targets = [coin.address],
      values = [0],
      calldatas = [coin.iface.encodeFunctionData('approve', [bob.address, 0])];
    const description = 'signature and NFT authorization';
    await h.send(governor, alice, 'propose', [targets, values, calldatas, description]);
    const id = (
      await h.read(governor, 'hashProposal', [targets, values, calldatas, ethers.id(description)])
    )[0];
    h.time = (await h.read(governor, 'proposalSnapshot', [id]))[0];
    const domain = {
      name: 'Digil Governor',
      version: '1',
      chainId: 1,
      verifyingContract: governor.address,
    };
    const types = {
      ExtendedBallot: [
        { name: 'proposalId', type: 'uint256' },
        { name: 'support', type: 'uint8' },
        { name: 'voter', type: 'address' },
        { name: 'nonce', type: 'uint256' },
        { name: 'reason', type: 'string' },
        { name: 'params', type: 'bytes' },
      ],
    };
    const params = ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [aliceNft]);
    const message = {
      proposalId: id,
      support: 1,
      voter: alice.address,
      nonce: 0,
      reason: 'signed ballot',
      params,
    };
    const wallet = new ethers.Wallet(ethers.hexlify(alice.key));
    const bad = await wallet.signTypedData(
      { ...domain, verifyingContract: coin.address },
      types,
      message
    );
    const args = (signature) => [id, 1, alice.address, message.reason, params, signature];
    await h.reverts(
      governor,
      carol,
      'castVoteWithReasonAndParamsBySig',
      args(bad),
      0n,
      'GovernorInvalidSignature'
    );
    assert.equal((await h.read(governor, 'nonces', [alice.address]))[0], 0n);
    const good = await wallet.signTypedData(domain, types, message);
    const voted = await h.send(governor, carol, 'castVoteWithReasonAndParamsBySig', args(good));
    assert.equal(h.events(governor, voted, 'VoteCastWithParams')[0].support, 1n);
    assert.equal((await h.read(governor, 'nonces', [alice.address]))[0], 1n);
    await h.reverts(
      governor,
      carol,
      'castVoteWithReasonAndParamsBySig',
      args(good),
      0n,
      'GovernorInvalidSignature'
    );
    await h.send(token, alice, 'transferFrom', [alice.address, bob.address, aliceNft]);
    await h.reverts(
      governor,
      bob,
      'castVoteWithReasonAndParams',
      [id, 1, '', params],
      0n,
      'AlreadyUsedNft'
    );
    const otherParams = ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [carolNft]);
    await h.reverts(
      governor,
      carol,
      'castVoteWithReasonAndParams',
      [id, 1, '', otherParams],
      0n,
      'InvalidParams'
    );
    assert.equal((await h.read(governor, 'hasVoted', [id, carol.address]))[0], false);
    await h.reverts(
      governor,
      bob,
      'castVoteWithReasonAndParams',
      [id, 1, '', otherParams],
      0n,
      'InsufficientApproval'
    );
    assert.equal((await h.read(governor, 'hasVoted', [id, bob.address]))[0], false);
    await h.send(token, carol, 'approve', [bob.address, carolNft]);
    await h.send(governor, bob, 'castVoteWithReasonAndParams', [
      id,
      2,
      'approved operator abstains',
      otherParams,
    ]);
    const totals = await h.read(governor, 'proposalVotes', [id]);
    assert.equal(
      totals.forVotes,
      totals.abstainVotes,
      'equal snapshot balances have equal quadratic weight'
    );
    assert.equal(totals.againstVotes, 0n);
  });

  test('Lock duration, extension, failed transfer rollback and exact unlock boundary', async ({
    coin,
    governor,
  }) => {
    await h.send(coin, admin, 'mint', [alice.address, 5000n * unit]);
    const min = 7n * 86400n,
      max = 1460n * 86400n;
    await h.reverts(governor, alice, 'lockCoins', [unit, min - 1n], 0n, 'LockDurationOutOfBounds');
    await h.reverts(governor, alice, 'lockCoins', [unit, max + 1n], 0n, 'LockDurationOutOfBounds');
    await h.reverts(governor, alice, 'lockCoins', [unit, min]);
    assert.equal((await h.read(coin, 'balanceOf', [governor.address]))[0], 0n);
    await h.send(coin, alice, 'approve', [governor.address, ethers.MaxUint256]);
    const locked = await h.send(governor, alice, 'lockCoins', [1000n * unit, min]);
    assert.equal(h.events(governor, locked, 'Lock')[0].amount, 1000n * unit);
    const extended = await h.send(governor, alice, 'lockCoins', [0, max]);
    const expiry = h.events(governor, extended, 'Lock')[0].expiry;
    await h.reverts(governor, alice, 'lockCoins', [0, min], 0n, 'NoLockAction');
    h.time = expiry - 2n;
    await h.reverts(governor, alice, 'unlockCoins', [], 0n, 'LockNotExpired');
    await h.send(governor, alice, 'unlockCoins');
    assert.equal(h.time, expiry);
    assert.equal((await h.read(coin, 'balanceOf', [alice.address]))[0], 5000n * unit);
    assert.equal((await h.read(coin, 'balanceOf', [governor.address]))[0], 0n);
    await h.reverts(governor, alice, 'unlockCoins', [], 0n, 'NoLockedCoins');
  });

  test('Reward snapshots, active-day boundaries, claimMany rollback and ETH conservation', async ({
    coin,
  }) => {
    const spender = await h.deploy('FeeSpender', [], false, 'tests/SecurityActors.sol');
    await h.send(coin, admin, 'mint', [alice.address, 10000n * unit]);
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 10000]);
    await h.send(coin, alice, 'approve', [spender.address, ethers.MaxUint256]);
    const start = (await h.read(coin, 'currentEpochStart'))[0];
    await h.send(coin, admin, 'donate', [], unit);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 49n * unit]);
    assert.equal((await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0].activeDays, 0n);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, unit]);
    assert.equal((await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0].activeDays, 1n);
    h.time = start + 86400n - 2n;
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 50n * unit]);
    assert.equal((await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0].activeDays, 1n);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 50n * unit]);
    assert.equal((await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0].activeDays, 2n);
    await h.send(coin, admin, 'setRewardParameters', [unit, 500n * unit, 5000n * unit, 500, 5]);
    assert.equal(
      (await h.read(coin, 'getEpoch', [0]))[0].dayBonusBps,
      100n,
      'current epoch retains its multiplier snapshot'
    );
    h.time = start + 30n * 86400n - 2n;
    await h.send(coin, alice, 'syncEpoch');
    assert.equal((await h.read(coin, 'currentEpochId'))[0], 0n);
    await h.send(coin, alice, 'syncEpoch');
    assert.equal((await h.read(coin, 'currentEpochId'))[0], 1n);
    assert.equal((await h.read(coin, 'getEpoch', [1]))[0].dayBonusBps, 500n);
    await h.send(coin, admin, 'donate', [], 2n * unit);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, unit]);
    h.time += 30n * 86400n;
    await h.send(coin, bob, 'syncEpoch');
    const first = (await h.read(coin, 'previewClaim', [alice.address, 0]))[0];
    const second = (await h.read(coin, 'previewClaim', [alice.address, 1]))[0];
    assert.equal(first + second, 3n * unit);
    await h.reverts(coin, alice, 'claimMany', [[0, 0]], 0n, 'AlreadyClaimed');
    assert.equal(
      (await h.read(coin, 'totalClaimedEth'))[0],
      0n,
      'duplicate batch rolls back its earlier claim'
    );
    await h.send(coin, alice, 'claimMany', [[0, 1]]);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], first + second);
    assert.equal((await h.read(coin, 'totalDonatedEth'))[0], first + second);
    assert.equal(await ethBalance(coin.address), 0n);
    await h.reverts(coin, alice, 'claimMany', [[0, 1]], 0n, 'AlreadyClaimed');
  });

  test('Forced ETH is credited exactly once without inventing donor points', async ({ coin }) => {
    const receiver = await actor();
    await h.send(receiver, admin, 'forceEth', [coin.address], 12345n);
    assert.equal(await ethBalance(coin.address), 12345n);
    assert.equal((await h.read(coin, 'totalDonatedEth'))[0], 0n);
    await h.send(coin, bob, 'syncUntrackedEth');
    assert.equal((await h.read(coin, 'totalDonatedEth'))[0], 12345n);
    await h.send(coin, bob, 'syncUntrackedEth');
    assert.equal((await h.read(coin, 'totalDonatedEth'))[0], 12345n);
    assert.equal((await h.read(coin, 'getUserEpoch', [bob.address, 0]))[0].points, 0n);
  });

  test('Collector yield obeys interval boundaries, saturation and pre-transfer balances', async ({
    coin,
    token,
  }) => {
    const id = await create(token);
    const withdraw = async (user) =>
      h.result(token, 'withdraw', await h.send(token, user, 'withdraw'))[0];
    assert.equal(await withdraw(alice), unit, 'initial payout is only the paid-creation gift');
    const cap = 100n * unit + unit / 7n;
    for (const elapsed of [899n, 900n, 901n, 90000n, 180000n]) {
      h.time += elapsed - 1n;
      const bonus = ((elapsed / 900n) * cap) / 100n;
      assert.equal(await withdraw(alice), bonus < cap ? bonus : cap, `yield at ${elapsed} seconds`);
    }
    assert.equal(await withdraw(bob), 0n, 'no NFT balance earns no yield');
    h.time += 90000n;
    await h.send(token, alice, 'transferFrom', [alice.address, bob.address, id]);
    assert.equal(
      await withdraw(alice),
      cap,
      'old holder receives accrued yield after transferring away'
    );
    assert.equal(
      await withdraw(bob),
      0n,
      'recipient cannot apply its old zero-balance timer to the received NFT'
    );
    h.time += 899n;
    assert.equal(await withdraw(bob), cap / 100n);
    const balance = (await h.read(coin, 'balanceOf', [bob.address]))[0];
    assert.equal(balance, cap / 100n, 'transfer never grants a welcome gift');
    assert.equal(await withdraw(bob), 0n, 'same interval cannot be paid twice');
  });

  test('ETH withdrawal rejection rolls back; reentrancy cannot double-pay', async ({
    coin,
    token,
  }) => {
    const receiver = await actor();
    const created = await invoke(receiver, token, 'createToken', [0, 0, false, 0, '0x'], floor);
    const id = h.events(token, created, 'Transfer')[0].tokenId;
    await invoke(receiver, token, 'dischargeToken', [id], floor);
    await h.send(receiver, admin, 'configure', [true, false, ZERO, '0x']);
    await h.reverts(receiver, admin, 'execute', [
      token.address,
      token.iface.encodeFunctionData('withdraw'),
    ]);
    assert.equal((await h.read(coin, 'balanceOf', [receiver.address]))[0], 0n);
    await h.send(receiver, admin, 'configure', [
      false,
      false,
      token.address,
      token.iface.encodeFunctionData('withdraw'),
    ]);
    await invoke(receiver, token, 'withdraw');
    assert.equal((await h.read(receiver, 'attempted'))[0], true);
    assert.equal((await h.read(receiver, 'reentered'))[0], false);
    assert.equal(await ethBalance(receiver.address), (floor * 95n) / 100n);
    assert.equal(
      (await h.read(coin, 'balanceOf', [receiver.address]))[0],
      2n * unit,
      'welcome gift plus the owner distribution bonus'
    );
    await invoke(receiver, token, 'withdraw');
    assert.equal(await ethBalance(receiver.address), (floor * 95n) / 100n);
    assert.equal((await h.read(coin, 'balanceOf', [receiver.address]))[0], 2n * unit);
  });

  test('A wallet can redirect its ETH while DIGIL, opt-out and yield stay with the claimant', async ({
    coin,
    token,
  }) => {
    const wallet = await actor();
    const recipient = await actor();
    const minted = await invoke(wallet, token, 'createToken', [0, 0, false, 0, '0x'], floor);
    const id = h.events(token, minted, 'Transfer')[0].tokenId;
    await invoke(wallet, token, 'dischargeToken', [id], floor);
    await h.send(wallet, admin, 'configure', [true, false, ZERO, '0x']);
    await h.send(recipient, admin, 'configure', [true, false, ZERO, '0x']);
    for (const address of [ZERO, recipient.address]) {
      await h.reverts(wallet, admin, 'execute', [
        token.address,
        token.iface.encodeFunctionData('withdrawTo', [address]),
      ]);
    }
    // A different account can only route its own credit.
    await h.send(token, bob, 'withdrawTo', [bob.address]);
    await h.send(recipient, admin, 'configure', [
      false,
      false,
      token.address,
      token.iface.encodeFunctionData('withdraw'),
    ]);
    await invoke(wallet, token, 'setOptStatus', [true], 100n * floor);
    await invoke(wallet, token, 'withdrawTo', [recipient.address]);
    const expectedETH = floor - floor / 20n;
    assert.equal(await ethBalance(recipient.address), expectedETH);
    assert.equal(await ethBalance(wallet.address), 0n);
    assert.equal((await h.read(recipient, 'attempted'))[0], true);
    assert.equal((await h.read(recipient, 'reentered'))[0], false);
    assert.equal((await h.read(coin, 'balanceOf', [wallet.address]))[0], 0n);
    await invoke(wallet, token, 'setOptStatus', [false], 100n * floor);
    await h.send(token, admin, 'createValue', [id, floor], floor);
    await invoke(wallet, token, 'dischargeToken', [id], floor);
    h.time += 900n; // One collector-yield interval for the wallet's NFT.
    await invoke(wallet, token, 'withdrawTo', [recipient.address]);
    const expectedDIGIL = 3n * unit + (100n * unit + unit / 7n) / 100n;
    assert.equal((await h.read(coin, 'balanceOf', [wallet.address]))[0], expectedDIGIL);
    assert.equal((await h.read(coin, 'balanceOf', [recipient.address]))[0], 0n);
    await invoke(wallet, token, 'withdrawTo', [recipient.address]);
    assert.equal(await ethBalance(recipient.address), 2n * expectedETH);
    assert.equal((await h.read(coin, 'balanceOf', [wallet.address]))[0], expectedDIGIL);
  });

  test('Reward claim failure preserves entitlement and blocks a reentrant claim', async ({
    coin,
  }) => {
    const receiver = await actor();
    const spender = await h.deploy('FeeSpender', [], false, 'tests/SecurityActors.sol');
    await h.send(coin, admin, 'mint', [receiver.address, 100n * unit]);
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 10000]);
    await invoke(receiver, coin, 'approve', [spender.address, ethers.MaxUint256]);
    await h.send(spender, admin, 'pay', [coin.address, receiver.address, 100n * unit]);
    await h.send(coin, admin, 'donate', [], unit);
    h.time += 30n * 86400n;
    await h.send(coin, bob, 'syncEpoch');
    await h.send(receiver, admin, 'configure', [true, false, ZERO, '0x']);
    await h.reverts(receiver, admin, 'execute', [
      coin.address,
      coin.iface.encodeFunctionData('claim', [0]),
    ]);
    assert.equal((await h.read(coin, 'previewClaim', [receiver.address, 0]))[0], unit);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], 0n);
    await h.send(receiver, admin, 'configure', [
      false,
      false,
      coin.address,
      coin.iface.encodeFunctionData('claim', [0]),
    ]);
    await invoke(receiver, coin, 'claim', [0]);
    assert.equal((await h.read(receiver, 'attempted'))[0], true);
    assert.equal((await h.read(receiver, 'reentered'))[0], false);
    assert.equal(await ethBalance(receiver.address), unit);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], unit);
  });

  test('ERC721 receiver rejection restores approval and custody', async ({ token }) => {
    const receiver = await actor();
    const id = await create(token);
    await h.send(token, alice, 'approve', [bob.address, id]);
    await h.send(receiver, admin, 'configure', [false, true, ZERO, '0x']);
    await h.reverts(token, bob, 'safeTransferFrom(address,address,uint256)', [
      alice.address,
      receiver.address,
      id,
    ]);
    assert.equal(
      (await h.read(token, 'ownerOf', [id]))[0].toLowerCase(),
      alice.address.toLowerCase()
    );
    assert.equal(
      (await h.read(token, 'getApproved', [id]))[0].toLowerCase(),
      bob.address.toLowerCase()
    );
    await h.send(receiver, admin, 'configure', [false, false, ZERO, '0x']);
    await h.send(token, bob, 'safeTransferFrom(address,address,uint256)', [
      alice.address,
      receiver.address,
      id,
    ]);
    assert.equal(
      (await h.read(token, 'ownerOf', [id]))[0].toLowerCase(),
      receiver.address.toLowerCase()
    );
    assert.equal((await h.read(token, 'getApproved', [id]))[0], ZERO);
  });

  test('False-returning ERC20 payout is retriable without duplicate entitlement', async () => {
    const coin = await h.deploy('FailingCoin', [], false, 'tests/SecurityActors.sol');
    const token = await h.deploy('DigilToken', [admin.address, coin.address, 18]);
    await create(token);
    await h.send(coin, admin, 'setFailures', [false, true]);
    await h.send(token, alice, 'withdraw');
    assert.equal((await h.read(coin, 'balanceOf', [alice.address]))[0], 0n);
    await h.send(coin, admin, 'setFailures', [false, false]);
    await h.send(token, alice, 'withdraw');
    assert.equal((await h.read(coin, 'balanceOf', [alice.address]))[0], unit);
    await h.send(token, alice, 'withdraw');
    assert.equal((await h.read(coin, 'balanceOf', [alice.address]))[0], unit);
  });

  test('Timelock single operations enforce delay, predecessor, cancellation and role revocation', async ({
    coin,
    timelock,
  }) => {
    for (const role of ['PROPOSER_ROLE', 'CANCELLER_ROLE'])
      await h.send(timelock, admin, 'grantRole', [ethers.id(role), alice.address]);
    await h.send(timelock, admin, 'grantRole', [ethers.id('EXECUTOR_ROLE'), bob.address]);
    const payload = coin.iface.encodeFunctionData('approve', [carol.address, 123]);
    const first = [coin.address, 0, payload, ethers.ZeroHash, ethers.id('first')];
    const id = (await h.read(timelock, 'hashOperation', first))[0];
    assert.equal((await h.read(timelock, 'getOperationState', [id]))[0], 0n);
    assert.equal((await h.read(timelock, 'isOperation', [id]))[0], false);
    await h.reverts(timelock, alice, 'schedule', [...first, 59], 0n, 'TimelockInsufficientDelay');
    const scheduled = await h.send(timelock, alice, 'schedule', [...first, 60]);
    assert.equal(h.events(timelock, scheduled, 'CallScheduled')[0].id, id);
    const eta = (await h.read(timelock, 'getTimestamp', [id]))[0];
    assert.equal((await h.read(timelock, 'getOperationState', [id]))[0], 1n);
    assert.equal((await h.read(timelock, 'isOperationReady', [id]))[0], false);
    const second = [coin.address, 0, payload, id, ethers.id('second')];
    await h.send(timelock, alice, 'schedule', [...second, 60]);
    h.time = eta - 2n;
    await h.reverts(timelock, bob, 'execute', first, 0n, 'TimelockUnexpectedOperationState');
    const executed = await h.send(timelock, bob, 'execute', first);
    assert.equal(h.time, eta, 'single operation executes at the exact timestamp');
    assert.equal(h.events(timelock, executed, 'CallExecuted')[0].id, id);
    assert.equal((await h.read(timelock, 'getOperationState', [id]))[0], 3n);
    assert.equal((await h.read(coin, 'allowance', [timelock.address, carol.address]))[0], 123n);
    await h.reverts(timelock, bob, 'execute', first, 0n, 'TimelockUnexpectedOperationState');
    h.time = eta + 60n;
    await h.send(timelock, bob, 'execute', second);
    const missing = [
      coin.address,
      0,
      payload,
      ethers.id('missing predecessor'),
      ethers.id('blocked'),
    ];
    await h.send(timelock, alice, 'schedule', [...missing, 60]);
    h.time += 60n;
    await h.reverts(timelock, bob, 'execute', missing, 0n, 'TimelockUnexecutedPredecessor');
    const missingId = (await h.read(timelock, 'hashOperation', missing))[0];
    await h.send(timelock, alice, 'cancel', [missingId]);
    assert.equal((await h.read(timelock, 'isOperation', [missingId]))[0], false);
    await h.send(timelock, admin, 'revokeRole', [ethers.id('PROPOSER_ROLE'), alice.address]);
    await h.reverts(
      timelock,
      alice,
      'schedule',
      [...missing, 60],
      0n,
      'AccessControlUnauthorizedAccount'
    );
  });

  test('Governance handoff works before and after bootstrap roles are removed', async ({
    coin,
    token,
    governor,
    timelock,
  }) => {
    await h.send(coin, admin, 'mint', [alice.address, 20000n * unit]);
    await h.send(coin, alice, 'delegate', [alice.address]);
    const nftId = await create(token);
    const adminRole = ethers.ZeroHash;
    for (const role of [
      adminRole,
      ethers.id('MINTER_ROLE'),
      ethers.id('PAUSER_ROLE'),
      ethers.id('CONFIG_ROLE'),
    ]) {
      await h.send(coin, admin, 'grantRole', [role, timelock.address]);
    }
    await h.send(token, admin, 'transferOwnership', [timelock.address]);
    for (let id = 0; id < 21; id++)
      assert.equal(
        (await h.read(token, 'ownerOf', [id]))[0].toLowerCase(),
        timelock.address.toLowerCase()
      );
    const cycle = async (label, weight, threshold, stored = false) => {
      const targets = [coin.address, token.address, governor.address];
      const values = [0, 0, 0];
      const calldatas = [
        coin.iface.encodeFunctionData('setSpendWeight', [token.address, weight]),
        token.iface.encodeFunctionData('configure', [100, floor, (floor * 90n) / 100n, 32]),
        governor.iface.encodeFunctionData('setProposalThreshold', [threshold]),
      ];
      const descriptionHash = ethers.id(label);
      await h.send(governor, alice, 'propose', [targets, values, calldatas, label]);
      const id = (
        await h.read(governor, 'hashProposal', [targets, values, calldatas, descriptionHash])
      )[0];
      assert.equal(
        (await h.read(governor, 'getProposalId', [targets, values, calldatas, descriptionHash]))[0],
        id
      );
      const count = (await h.read(governor, 'proposalCount'))[0];
      const details = await h.read(governor, 'proposalDetails', [id]);
      assert.deepEqual(
        Array.from(details[0], (at) => at.toLowerCase()),
        targets.map((at) => at.toLowerCase())
      );
      assert.deepEqual(Array.from(details[1]), [0n, 0n, 0n]);
      assert.deepEqual(Array.from(details[2]), calldatas);
      assert.equal(details[3], descriptionHash);
      assert.equal((await h.read(governor, 'proposalDetailsAt', [count - 1n]))[0], id);
      assert.equal(
        (await h.read(governor, 'proposalProposer', [id]))[0].toLowerCase(),
        alice.address.toLowerCase()
      );
      assert.equal((await h.read(governor, 'proposalNeedsQueuing', [id]))[0], true);
      assert.deepEqual(Array.from(await h.read(governor, 'proposalMarkets', [id])), [
        0n,
        0n,
        false,
      ]);
      const params = ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [nftId]);
      h.time = (await h.read(governor, 'proposalSnapshot', [id]))[0] - 1n;
      await h.reverts(governor, alice, 'castVoteWithReasonAndParams', [id, 1, '', params]);
      await h.send(governor, alice, 'castVoteWithReasonAndParams', [
        id,
        1,
        'handoff rehearsal',
        params,
      ]);
      const snapshot = (await h.read(governor, 'proposalSnapshot', [id]))[0];
      assert.equal(
        (await h.read(governor, 'getVotes', [alice.address, snapshot]))[0],
        20000n * unit
      );
      assert.equal(
        (await h.read(governor, 'getVotesWithParams', [alice.address, snapshot, params]))[0],
        20000n * unit
      );
      const votes = (await h.read(governor, 'proposalVotes', [id])).forVotes;
      assert.equal((await h.read(governor, 'quorum', [snapshot]))[0], (votes * 4n) / 100n);
      assert.equal((await h.read(governor, 'hasVoted', [id, alice.address]))[0], true);
      await h.reverts(governor, alice, 'castVoteWithReasonAndParams', [id, 1, '', params]);
      h.time = (await h.read(governor, 'proposalDeadline', [id]))[0];
      await h.send(governor, bob, 'finalizeMarket', [id]);
      assert.equal((await h.read(governor, 'marketOutcome', [id]))[0], 2n);
      const args = [targets, values, calldatas, descriptionHash];
      await h.send(
        governor,
        bob,
        stored ? 'queue(uint256)' : 'queue(address[],uint256[],bytes[],bytes32)',
        stored ? [id] : args
      );
      const eta = (await h.read(governor, 'proposalEta', [id]))[0];
      h.time = eta - 2n;
      await h.reverts(governor, bob, 'execute(address[],uint256[],bytes[],bytes32)', args);
      const executed = await h.send(
        governor,
        bob,
        stored ? 'execute(uint256)' : 'execute(address[],uint256[],bytes[],bytes32)',
        stored ? [id] : args
      );
      assert.equal(h.events(token, executed, 'Configure').length, 1);
      assert.equal((await h.read(coin, 'spendWeightBps', [token.address]))[0], BigInt(weight));
      assert.equal((await h.read(governor, 'proposalThreshold'))[0], threshold);
      assert.equal((await h.read(governor, 'state', [id]))[0], 7n);
      assert.equal((await h.read(governor, 'marketOutcome', [id]))[0], 2n);
      await h.reverts(governor, bob, 'execute(address[],uint256[],bytes[],bytes32)', args);
    };
    await cycle('pre-revocation handoff rehearsal', 9000, 11000n * unit);
    for (const role of [
      ethers.id('MINTER_ROLE'),
      ethers.id('PAUSER_ROLE'),
      ethers.id('CONFIG_ROLE'),
      adminRole,
    ]) {
      await h.send(coin, admin, 'renounceRole', [role, admin.address]);
      assert.equal((await h.read(coin, 'hasRole', [role, admin.address]))[0], false);
    }
    await h.send(timelock, admin, 'renounceRole', [adminRole, admin.address]);
    assert.equal((await h.read(timelock, 'hasRole', [adminRole, admin.address]))[0], false);
    assert.equal((await h.read(timelock, 'hasRole', [adminRole, timelock.address]))[0], true);
    await h.reverts(
      coin,
      admin,
      'mint',
      [admin.address, unit],
      0n,
      'AccessControlUnauthorizedAccount'
    );
    await h.reverts(
      coin,
      admin,
      'setSpendWeight',
      [token.address, 0],
      0n,
      'AccessControlUnauthorizedAccount'
    );
    await h.reverts(
      token,
      admin,
      'configure',
      [100, floor, (floor * 90n) / 100n, 32],
      0n,
      'OwnableUnauthorizedAccount'
    );
    await h.reverts(governor, admin, 'setProposalThreshold', [0], 0n, 'GovernorOnlyExecutor');
    await h.reverts(
      timelock,
      admin,
      'grantRole',
      [adminRole, admin.address],
      0n,
      'AccessControlUnauthorizedAccount'
    );
    await cycle('post-revocation handoff rehearsal', 10000, 10000n * unit, true);
    const cancelArgs = [
      [coin.address],
      [0],
      [coin.iface.encodeFunctionData('approve', [bob.address, 0])],
      'cancel stored proposal',
    ];
    await h.send(governor, alice, 'propose', cancelArgs);
    const cancelId = (
      await h.read(governor, 'getProposalId', [...cancelArgs.slice(0, 3), ethers.id(cancelArgs[3])])
    )[0];
    await h.reverts(governor, bob, 'cancel(uint256)', [cancelId]);
    await h.send(governor, alice, 'cancel(uint256)', [cancelId]);
    assert.equal((await h.read(governor, 'marketOutcome', [cancelId]))[0], 3n);
    assert.equal((await h.read(governor, 'state', [cancelId]))[0], 2n);
    const before = (await h.read(coin, 'balanceOf', [alice.address]))[0];
    await h.send(token, alice, 'withdraw');
    assert.ok(
      (await h.read(coin, 'balanceOf', [alice.address]))[0] > before,
      'Token minter permission survives governance handoff'
    );
    assert.equal(
      (await h.read(coin, 'hasRole', [ethers.id('MINTER_ROLE'), token.address]))[0],
      true
    );
  });

  let passed = 0,
    failed = 0;
  for (const { name, run } of tests) {
    try {
      h.scenario = null;
      const fixture = await fullBootstrap(h);
      h.scenario = name;
      await run(fixture);
      passed++;
      console.log(`PASS ${name}`);
    } catch (error) {
      failed++;
      console.error(`FAIL ${name}:`, error);
    }
  }
  console.log(`Extended protocol scenarios: ${passed} passed; ${failed} failed`);
  h.writeCoverage();
  assert.equal(failed, 0);
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
