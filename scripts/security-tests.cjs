const assert = require('node:assert/strict');
const { compile, sourcesIn, checkSizes } = require('./compile.cjs');
const { createHarness, bootstrap, unit, floor, ethers } = require('./evm.cjs');

async function main() {
  const contracts = compile({ ...sourcesIn('contracts'), ...sourcesIn('tests', f => f === 'SecurityActors.sol') });
  const diagnostic = process.argv.includes('--diagnostic');
  if (diagnostic) console.warn('DIAGNOSTIC ONLY: code-size exemptions enabled; not a deployment validation.');
  else checkSizes(contracts);
  const h = await createHarness(contracts, diagnostic);
  const { coin, token } = await bootstrap(h);
  const [admin, alice, bob, carol, dave] = h.users;
  for (const user of h.users.slice(0, 5)) {
    await h.send(coin, admin, 'mint', [user.address, 1000000n * unit]);
    await h.send(coin, user, 'approve', [token.address, ethers.MaxUint256]);
  }
  const spender = await h.deploy('FeeSpender', [], true, 'tests/SecurityActors.sol');
  const timelock = await h.deploy('DigilTimelock', [1, [], [ethers.ZeroAddress], admin.address]);
  const governor = await h.deploy('DigilGovernor', [coin.address, timelock.address, token.address]);
  await h.send(timelock, admin, 'grantRole', [ethers.id('PROPOSER_ROLE'), governor.address]);
  await h.send(timelock, admin, 'grantRole', [ethers.id('CANCELLER_ROLE'), governor.address]);
  await h.send(timelock, admin, 'grantRole', [ethers.id('CANCELLER_ROLE'), admin.address]);
  await h.send(coin, admin, 'delegate', [admin.address]);
  for (const user of h.users.slice(0, 5)) await h.send(coin, user, 'approve', [governor.address, ethers.MaxUint256]);
  const balance = async user => (await h.read(coin, 'balanceOf', [user.address]))[0];
  const points = async user => (await h.read(coin, 'getUserEpoch', [user.address, 0]))[0].points;
  const create = async (user = alice, iv = 0n, threshold = 0n, plane = 0, data = '0x') =>
    h.result(token, 'createToken', await h.send(token, user, 'createToken', [iv, threshold, false, plane, data], floor))[0];
  const withdraw = async user => h.result(token, 'withdraw', await h.send(token, user, 'withdraw'));
  const mintId = result => h.events(token, result, 'Transfer').find(event => event.from === ethers.ZeroAddress).tokenId;
  const proposal = async description => {
    const targets = [coin.address], values = [0], calldatas = [coin.iface.encodeFunctionData('approve', [dave.address, 0])];
    await h.send(governor, admin, 'propose', [targets, values, calldatas, description]);
    const hash = ethers.id(description);
    const id = (await h.read(governor, 'hashProposal', [targets, values, calldatas, hash]))[0];
    return { id, targets, values, calldatas, hash };
  };
  const finishVote = async (p, support = 1) => {
    h.time = (await h.read(governor, 'proposalSnapshot', [p.id]))[0];
    if (support !== null) await h.send(governor, admin, 'castVoteWithReasonAndParams',
      [p.id, support, '', ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [0])]);
    h.time = (await h.read(governor, 'proposalDeadline', [p.id]))[0] + 1n;
  };
  const queue = p => h.send(governor, admin, 'queue(address[],uint256[],bytes[],bytes32)', [p.targets, p.values, p.calldatas, p.hash]);
  const cancelQueued = async p => {
    const salt = ethers.toBeHex((BigInt(governor.address) << 96n) ^ BigInt(p.hash), 32);
    const operation = (await h.read(timelock, 'hashOperationBatch', [p.targets, p.values, p.calldatas, ethers.ZeroHash, salt]))[0];
    await h.send(timelock, admin, 'cancel', [operation]);
  };
  const linkCost = (efficiency, count, fresh, bonus = 0n) => {
    const excess = BigInt(efficiency) > 200n / BigInt(count) ? BigInt(efficiency) - 200n / BigInt(count) : 0n;
    let cost = (BigInt(efficiency) + excess * (excess + 1n) / 2n) * 100n * unit;
    if (bonus > 0n) cost = cost * 100n / (100n + bonus);
    if (fresh && count <= 2) cost /= 2n;
    return cost;
  };
  const tests = [];
  const test = (name, run) => tests.push({ name, run });

  test('Interfaces retain matching function, event, and error signatures', async () => {
    for (const [interfaceName, implementation] of [['IDigilToken', 'DigilToken'], ['IDigilCoin', 'DigilCoin']]) {
      const expected = contracts[`contracts/${interfaceName}.sol`][interfaceName].abi;
      const actual = contracts[`contracts/${implementation}.sol`][implementation].abi;
      const key = entry => `${entry.type}:${entry.name}(${(entry.inputs || []).map(x => x.type).join(',')})`;
      for (const entry of expected.filter(x => ['function', 'event', 'error'].includes(x.type))) {
        const found = actual.find(x => key(x) === key(entry));
        assert.ok(found, key(entry));
        assert.deepEqual((found.outputs || []).map(x => x.type), (entry.outputs || []).map(x => x.type));
        if (entry.type === 'event') assert.deepEqual(found.inputs.map(x => !!x.indexed), entry.inputs.map(x => !!x.indexed));
      }
    }
  });

  test('Only explicit weighted fees earn points; allowance, pause, and payer attribution hold', async () => {
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 5000]);
    await h.send(coin, alice, 'approve', [spender.address, 1000n * unit]);
    await h.send(spender, bob, 'deposit', [coin.address, alice.address, 200n * unit]);
    assert.equal(await points(alice), 0n);
    await h.send(spender, bob, 'refund', [coin.address, alice.address, 200n * unit]);
    await h.send(coin, alice, 'transfer', [spender.address, unit]);
    await h.send(coin, alice, 'burn', [unit]);
    assert.equal(await points(alice), 0n);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 100n * unit]);
    assert.equal(await points(alice), 100n * unit * 5000n);
    assert.equal(await points(bob), 0n);
    assert.equal((await h.read(coin, 'allowance', [alice.address, spender.address]))[0], 700n * unit);
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 0]);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 50n * unit]);
    assert.equal(await points(alice), 100n * unit * 5000n);
    await h.send(coin, admin, 'pause');
    await h.reverts(spender, bob, 'pay', [coin.address, alice.address, unit]);
    await h.send(coin, admin, 'unpause');
    await h.send(coin, alice, 'approve', [spender.address, 0]);
    await h.reverts(spender, bob, 'pay', [coin.address, alice.address, unit]);
  });

  test('Feature-fee integrations include paid alignment, metadata, links, prime, stabilize, and vault', async () => {
    await h.send(coin, admin, 'setRewardParameters', [unit, 1000000n * unit, 10000000n * unit, 100, 20]);
    const before = await balance(alice);
    const id = await create(alice, 0n, 1000n * unit, 8);
    const dest = await create(alice);
    await h.send(token, alice, 'updateToken', [id, 0, 1000n * unit, '0x1234', 'ipfs://paid'], floor);
    await h.send(token, alice, 'linkToken', [id, dest, 1]);
    await h.send(token, alice, 'linkToken', [id, dest, 2]);
    await h.send(token, alice, 'primeToken', [id]);
    await h.send(token, alice, 'activateToken', [dest]);
    await h.send(token, alice, 'overchargeToken', [dest, unit], 2n * floor);
    await h.send(token, alice, 'stabilizeToken', [dest]);
    const nft = await h.deploy('NFT');
    await h.send(nft, admin, 'mint', [alice.address, 1]);
    await h.send(nft, alice, 'safeTransferFrom(address,address,uint256)', [alice.address, token.address, 1]);
    await h.send(token, alice, 'vaultToken', [nft.address, 1, '0x']);
    assert.equal(await points(alice), (before - await balance(alice)) * 10000n);
    assert.ok(await points(alice) > 0n);
  });

  test('Refunded, sponsored, and active charges earn no donor rewards', async () => {
    const id = await create(alice, 0n, 1000n * unit);
    const before = await balance(bob);
    await h.send(coin, admin, 'donate', [], unit);
    await h.send(token, bob, 'chargeToken', [id, 500n * unit]);
    await h.send(token, alice, 'dischargeToken', [id], floor);
    assert.equal((await withdraw(bob))[0], 500n * unit);
    assert.equal(await balance(bob), before);
    assert.equal(await points(bob), 0n);
    await h.send(token, bob, 'chargeTokenAs', [carol.address, id, unit], floor);
    assert.equal(await points(bob), 0n);
    assert.equal(await points(carol), 0n);
    const active = await create(alice);
    await h.send(token, alice, 'activateToken', [active]);
    await h.send(token, bob, 'chargeToken', [active, unit]);
    assert.equal(await points(bob), 0n);
    h.time += 30n * 86400n;
    await h.send(coin, bob, 'claim', [0]);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], 0n);
  });

  test('Epoch caps, rollover, claims, and replay guards still apply to explicit fees', async () => {
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 10000]);
    await h.send(coin, alice, 'approve', [spender.address, ethers.MaxUint256]);
    await h.send(coin, admin, 'donate', [], unit);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 600n * unit]);
    assert.equal(await points(alice), 500n * unit * 10000n);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, unit]);
    assert.equal(await points(alice), 500n * unit * 10000n);
    h.time += 86400n;
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 50n * unit]);
    assert.equal(await points(alice), 550n * unit * 10000n);
    h.time += 30n * 86400n;
    await h.send(coin, alice, 'claim', [0]);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], unit);
    await h.reverts(coin, alice, 'claim', [0], 0n, 'AlreadyClaimed');
    h.time += 13n * 30n * 86400n;
    await h.send(spender, bob, 'pay', [coin.address, alice.address, unit]);
    assert.ok((await h.read(coin, 'currentEpochId'))[0] >= 14n);
    await h.reverts(coin, alice, 'claim', [0]);
  });

  test('Welcome gifts require paid creation and share eligibility with paid vaulting', async () => {
    assert.equal((await withdraw(admin))[0], 0n, 'Constructor planar mints grant no gift');
    const id = await create(alice);
    assert.equal((await withdraw(alice))[0], unit);
    let owner = alice;
    for (const recipient of [bob, carol, dave]) {
      await h.send(token, owner, 'transferFrom', [owner.address, recipient.address, id]);
      assert.equal((await withdraw(recipient))[0], 0n);
      owner = recipient;
    }
    const nft = await h.deploy('NFT');
    await h.send(nft, admin, 'mint', [bob.address, 1]);
    await h.send(nft, bob, 'safeTransferFrom(address,address,uint256)', [bob.address, token.address, 1]);
    await h.send(token, bob, 'vaultToken', [nft.address, 1, '0x']);
    assert.equal((await withdraw(bob))[0], unit, 'A former recipient can earn the paid-vault gift');
    await create(bob);
    assert.equal((await withdraw(bob))[0], 0n, 'Vault and create share eligibility');
    await create(alice);
    assert.equal((await withdraw(alice))[0], 0n, 'Selling all NFTs does not reset eligibility');
    await create(carol);
    assert.equal((await withdraw(carol))[0], unit, 'A former recipient can earn the creation gift');
  });

  test('Superseded wrappers never report custody or regain recall rights', async () => {
    const nft = await h.deploy('NFT');
    await h.send(nft, admin, 'mint', [bob.address, 0]);
    const wrap = async () => {
      await h.send(nft, bob, 'safeTransferFrom(address,address,uint256)', [bob.address, token.address, 0]);
      return mintId(await h.send(token, bob, 'vaultToken', [nft.address, 0, '0x']));
    };
    const oldId = await wrap();
    await h.send(token, bob, 'activateToken', [oldId]);
    await h.send(token, bob, 'recallToken', [nft.address, 0]);
    const newId = await wrap();
    await h.send(token, bob, 'deactivateToken', [oldId]);
    await h.send(token, bob, 'activateToken', [oldId]);
    const old = await h.read(token, 'tokenAttachment', [oldId]);
    assert.equal(old[0].toLowerCase(), nft.address.toLowerCase());
    assert.deepEqual(Array.from(old).slice(2), [false, false]);
    assert.deepEqual(Array.from(await h.read(token, 'tokenAttachment', [newId])).slice(2), [false, true]);
    await h.reverts(token, bob, 'recallToken', [nft.address, 0]);
    await h.send(token, bob, 'activateToken', [newId]);
    await h.send(token, bob, 'recallToken', [nft.address, 0]);
    assert.equal((await h.read(nft, 'ownerOf', [0]))[0].toLowerCase(), bob.address.toLowerCase());
  });

  test('Failed creation fees roll back minting, reward points, and welcome eligibility', async () => {
    const before = await balance(bob);
    await h.send(coin, bob, 'approve', [token.address, 0]);
    await h.reverts(token, bob, 'createToken', [0, 0, false, 8, '0x'], floor, 'CoinTransferFailed');
    await h.send(coin, bob, 'approve', [token.address, ethers.MaxUint256]);
    await h.send(coin, admin, 'pause');
    await h.reverts(token, bob, 'createToken', [0, 0, false, 8, '0x'], floor, 'CoinTransferFailed');
    await h.send(coin, admin, 'unpause');
    assert.equal((await h.read(token, 'balanceOf', [bob.address]))[0], 0n);
    assert.equal(await balance(bob), before);
    assert.equal(await points(bob), 0n);
    await create(bob, 0n, 0n, 8);
    assert.equal((await withdraw(bob))[0], unit);
  });

  test('Dynamic metadata and vault payloads preserve contents across storage-word boundaries', async () => {
    await h.send(coin, admin, 'mint', [alice.address, 2000000n * unit]);
    const nft = await h.deploy('NFT');
    for (const length of [0, 1, 31, 32, 33, 1024, 4096]) {
      const payload = '0x' + 'ab'.repeat(length);
      const id = await create(alice, 0n, 0n, 0, payload);
      assert.equal((await h.read(token, 'tokenData', [id]))[8], payload);
      const uri = 'ipfs://' + 'x'.repeat(length);
      await h.send(token, alice, 'updateToken', [id, 0, 0, payload, uri], floor);
      assert.equal((await h.read(token, 'tokenData', [id]))[8], payload);
      assert.equal((await h.read(token, 'tokenURI', [id]))[0], uri);
      await h.send(nft, admin, 'mint', [alice.address, length]);
      await h.send(nft, alice, 'safeTransferFrom(address,address,uint256,bytes)', [alice.address, token.address, length, payload]);
      const wrapper = mintId(await h.send(token, alice, 'vaultToken', [nft.address, length, payload]));
      assert.equal((await h.read(token, 'tokenData', [wrapper]))[8], payload);
      assert.equal((await h.read(token, 'tokenAttachment', [wrapper]))[3], true);
    }
  });

  test('No-op updates, whitelist entries, self-transfers, and zero enrichment do not postpone reclaim', async () => {
    const id = await create(alice, floor, 100n * unit, 0, '0x1234');
    await h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x', 'ipfs://same'], floor);
    await h.send(token, alice, 'restrictToken', [id, [bob.address]], floor);
    await h.send(token, bob, 'chargeToken', [id, unit], floor);
    h.time += 90n * 86400n;
    await h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x', '']);
    await h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x1234', 'ipfs://same'], floor);
    await h.send(token, alice, 'restrictToken', [id, [bob.address]]);
    await h.send(token, alice, 'transferFrom', [alice.address, alice.address, id]);
    await h.send(token, admin, 'createValue', [id, 0], floor);
    await h.send(token, bob, 'reclaimContribution', [id], floor);
    assert.equal((await withdraw(bob))[1], floor);
    await h.reverts(token, bob, 'reclaimContribution', [id], floor);
  });

  test('Genuine metadata, whitelist, enrichment, and ownership changes restart inactivity', async () => {
    const actions = [
      id => h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x01', ''], floor),
      id => h.send(token, alice, 'restrictToken', [id, [bob.address, carol.address]]),
      id => h.send(token, admin, 'createValue', [id, floor], floor),
      id => h.send(token, alice, 'transferFrom', [alice.address, carol.address, id]),
    ];
    for (const action of actions) {
      const id = await create(alice, floor, 100n * unit);
      await h.send(token, alice, 'restrictToken', [id, [bob.address]], floor);
      await h.send(token, bob, 'chargeToken', [id, unit], floor);
      h.time += 90n * 86400n;
      await action(id);
      await h.reverts(token, bob, 'reclaimContribution', [id], floor);
      h.time += 90n * 86400n;
      await h.send(token, bob, 'reclaimContribution', [id], floor);
    }
  });

  test('Permanent affinity acquired during attunement survives expiry', async () => {
    const source = await create(alice, 0n, 0n, 4);
    const dest = await create(alice, 0n, 0n, 4);
    await h.send(token, alice, 'activateToken', [source]);
    await h.send(token, alice, 'overchargeToken', [source, 1000n * unit], 2000n * floor);
    await h.send(token, alice, 'buffToken', [source, 0, 17, 0, 0, 0, 1]);
    await h.send(token, alice, 'linkToken', [source, dest, 100]);
    assert.equal((await h.read(token, 'tokenLinkAt', [source, 1]))[2], 400n);
    h.time += 120n;
    assert.equal((await h.read(token, 'tokenLinkAt', [source, 1]))[2], 400n);
  });

  test('Maximum link efficiency, buff discount, ten-link settlement, and last-element removal remain bounded', async () => {
    await h.send(coin, admin, 'mint', [alice.address, 100000000n * unit]);
    const source = await create(alice);
    const targets = [];
    for (let count = 1; count <= 10; count++) {
      const destination = await create(alice);
      targets.push(destination);
      const before = await balance(alice);
      await h.send(token, alice, 'linkToken', [source, destination, 254]);
      assert.equal(before - await balance(alice), linkCost(254, count, true));
    }
    const extra = await create(alice);
    await h.reverts(token, alice, 'linkToken', [source, extra, 255]);
    assert.equal((await h.read(token, 'tokenData', [source]))[4], 10n);
    await h.send(token, alice, 'activateToken', [source]);
    await h.send(token, alice, 'overchargeToken', [source, 5000n * unit], 10000n * floor);
    await h.send(token, alice, 'buffToken', [source, 100, 0, 0, 0, 0, 2]);
    for (const destination of targets) {
      const before = await balance(alice);
      await h.send(token, alice, 'linkToken', [source, destination, 255]);
      assert.equal(before - await balance(alice), linkCost(255, 10, false, 100n) - linkCost(254, 10, false, 100n));
      await h.send(token, alice, 'activateToken', [destination]);
    }
    await h.reverts(token, alice, 'linkToken', [source, targets[0], 255]);
    const charge = (await h.read(token, 'tokenCharge', [source]))[1];
    await h.send(token, alice, 'dischargeToken', [source], 10n * floor);
    for (const destination of targets) assert.equal((await h.read(token, 'tokenCharge', [destination]))[1], charge / 10n);
    assert.equal((await h.read(token, 'tokenCharge', [source]))[1], 0n);
    for (let i = 0; i < targets.length; i++) {
      await h.send(token, alice, 'unlinkToken', [source, targets[i]]);
      assert.equal((await h.read(token, 'tokenData', [source]))[4], BigInt(9 - i));
    }
    await h.reverts(token, alice, 'unlinkToken', [source, targets[0]]);
  });

  test('Affinity arithmetic preserves strong, moderate, weak, ethereal, and stronger-destination bounds', async () => {
    await h.send(coin, admin, 'mint', [alice.address, 100000000n * unit]);
    const pairs = [[4, 5], [4, 4], [4, 18], [4, 10], [4, 1], [12, 2], [12, 12], [17, 1], [17, 17], [18, 17]];
    let maximum = 0n;
    for (const [sourcePlane, destinationPlane] of pairs) {
      const source = await create(alice, 0n, 0n, sourcePlane);
      const destination = await create(alice, 0n, 0n, destinationPlane);
      const s = ethers.getBytes((await h.read(token, 'tokenData', [sourcePlane]))[8]);
      const d = ethers.getBytes((await h.read(token, 'tokenData', [destinationPlane]))[8]);
      for (const efficiency of [1n, 255n]) {
        let expected = 0n;
        if (s[1] === d[0] || s[2] === d[0]) expected = efficiency * 2n;
        else if (sourcePlane === destinationPlane || sourcePlane > 16) expected = efficiency;
        else if (s[3] === d[0]) expected = efficiency / 2n;
        else if (s[4] === d[0]) expected = efficiency / 4n;
        if (sourcePlane > 16) expected *= 4n;
        else if (sourcePlane > 11 || destinationPlane === 18) expected *= 2n;
        await h.send(token, alice, 'linkToken', [source, destination, efficiency]);
        const actual = (await h.read(token, 'tokenLinkAt', [source, 1]))[2];
        assert.equal(actual, expected);
        assert.ok(actual <= 2040n);
        if (actual > maximum) maximum = actual;
      }
    }
    assert.equal(maximum, 2040n);
    await h.send(token, admin, 'overchargeToken', [5, unit], 2n * floor);
    const source = await create(alice, 0n, 0n, 4);
    const destination = await create(alice, 0n, 0n, 5);
    await h.send(token, alice, 'linkToken', [source, destination, 255]);
    assert.equal((await h.read(token, 'tokenLinkAt', [source, 1]))[2], 255n);
  });

  test('New-link buff charges stop exactly at expiry and insufficient active charge still reverts', async () => {
    const source = await create(alice);
    const first = await create(alice);
    const second = await create(alice);
    await h.send(token, alice, 'activateToken', [source]);
    await h.send(token, alice, 'overchargeToken', [source, 1000n * unit], 2000n * floor);
    await h.send(token, alice, 'buffToken', [source, 100, 0, 0, 0, 0, 1]);
    const expiry = (await h.read(token, 'tokenBuff', [source]))[0];
    const beforeCharge = (await h.read(token, 'tokenCharge', [source]))[1];
    let beforeCoins = await balance(alice);
    h.time = expiry - 2n; // h.send advances the timestamp by one second.
    await h.send(token, alice, 'linkToken', [source, first, 255]);
    assert.equal(beforeCoins - await balance(alice), linkCost(255, 1, true, 100n));
    assert.equal((await h.read(token, 'tokenCharge', [source]))[1], beforeCharge - 100n * unit);
    beforeCoins = await balance(alice);
    await h.send(token, alice, 'linkToken', [source, second, 254]);
    assert.equal(h.time, expiry);
    assert.equal(beforeCoins - await balance(alice), linkCost(254, 2, true));
    assert.equal((await h.read(token, 'tokenCharge', [source]))[1], beforeCharge - 100n * unit);
    const depleted = await create(alice);
    await h.send(token, alice, 'activateToken', [depleted]);
    await h.send(token, alice, 'overchargeToken', [depleted, 100n * unit], 200n * floor);
    await h.send(token, alice, 'buffToken', [depleted, 100, 0, 0, 0, 0, 1]);
    beforeCoins = await balance(alice);
    await h.reverts(token, alice, 'linkToken', [depleted, first, 1], 0n, 'InsufficientActiveCharge');
    assert.equal(await balance(alice), beforeCoins);
    assert.equal((await h.read(token, 'tokenData', [depleted]))[4], 0n);
    assert.equal((await h.read(token, 'tokenCharge', [depleted]))[1], 0n);
  });

  test('Discharge keepers share only the fixed ETH fee, including final batches across repeated cycles', async () => {
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    const id = await create(alice, floor, 1000n * unit);
    await withdraw(alice);
    const contributors = h.users.slice(10, 43);
    for (let cycle = 0; cycle < 2; cycle++) {
      for (const user of contributors) await h.send(token, admin, 'chargeTokenAs', [user.address, id, unit], floor);
      await h.send(token, alice, 'dischargeToken', [id], floor);
      const first = await withdraw(alice);
      assert.equal(first[0], 0n);
      assert.equal(first[1], (floor / 10n) * 32n / 33n);
      await h.reverts(token, carol, 'dischargeToken', [id], 1n);
      await h.reverts(token, alice, 'transferFrom', [alice.address, bob.address, id]);
      await h.reverts(token, admin, 'chargeToken', [id, unit]);
      await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 64]);
      await h.send(token, dave, 'dischargeToken', [id]);
      const last = await withdraw(dave);
      assert.equal(last[0], 0n);
      assert.equal(first[1] + last[1], floor / 10n);
      for (const user of contributors) {
        const refund = await withdraw(user);
        assert.equal(refund[0], unit);
        assert.equal(refund[1], floor);
      }
      assert.equal((await h.read(token, 'tokenData', [id]))[7], 0n);
      assert.equal((await h.read(token, 'tokenData', [id]))[6], BigInt(cycle + 1));
      await withdraw(alice); // Any residual owner intrinsic value is separate from keeper rewards.
      await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    }
  });

  test('Activation rewards use actual direct deposits, exclude linked charge, and pay final-batch rounding', async () => {
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    const id = await create(alice);
    await withdraw(alice);
    const source = await create(bob);
    await h.send(token, bob, 'activateToken', [source]);
    await h.send(token, bob, 'linkToken', [source, id, 200]);
    await h.send(token, bob, 'chargeToken', [source, 100n * unit]);
    // Linked efficiency can create more charge than the directly deposited coins.
    for (const user of h.users.slice(10, 43)) {
      await h.send(coin, admin, 'mint', [user.address, unit + 16n]);
      await h.send(coin, user, 'approve', [token.address, unit + 16n]);
      await h.send(token, user, 'chargeToken', [id, unit + 16n]);
    }
    await h.send(token, alice, 'activateToken', [id]);
    const first = await withdraw(alice);
    assert.equal(first[0], 31n * (unit + 16n) / 100n);
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 64]);
    await h.send(token, dave, 'activateToken', [id]);
    const last = await withdraw(dave);
    assert.equal(first[0] + last[0], 33n * (unit + 16n) / 100n);
    assert.equal(last[0], 2n * (unit + 16n) / 100n + 1n, 'Final batch receives the rounding carry');
    assert.ok(last[0] > 0n);
    await h.reverts(token, dave, 'activateToken', [id]);
  });

  test('Single-batch and empty settlements grant no keeper allocation', async () => {
    const id = await create(alice);
    // Keep the operator separate from the owner and contributor's ordinary payouts.
    await h.send(token, alice, 'approve', [bob.address, id]);
    await h.send(token, carol, 'chargeToken', [id, 100n * unit]);
    await h.send(token, bob, 'dischargeToken', [id], floor);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
    assert.deepEqual(Array.from(await withdraw(carol)), [100n * unit, 0n]);
    await h.reverts(token, bob, 'dischargeToken', [id], floor);
    await h.send(token, carol, 'chargeToken', [id, 100n * unit]);
    await h.send(token, bob, 'activateToken', [id]);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
    const empty = await create(alice);
    await h.send(token, alice, 'approve', [bob.address, empty]);
    await h.send(token, bob, 'activateToken', [empty]);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
    await h.reverts(token, bob, 'activateToken', [empty]);
  });

  test('Exact batch endpoints complete once and preserve starter authorization and keeper totals', async () => {
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    for (const count of [31, 32, 64]) {
      const id = await create(alice);
      await h.send(token, alice, 'approve', [bob.address, id]);
      for (let i = 0; i < count; i++) {
        const contributor = ethers.getAddress(ethers.toBeHex(1000 + i, 20));
        await h.send(token, admin, 'chargeTokenAs', [contributor, id, unit], floor);
      }
      await h.reverts(token, carol, 'activateToken', [id]);
      const first = await h.send(token, bob, 'activateToken', [id]);
      assert.equal(h.result(token, 'activateToken', first)[0], count <= 32);
      if (count === 64) {
        const pending = await h.read(token, 'tokenData', [id]);
        assert.equal(pending[1], true);
        assert.equal(pending[7], 32n);
        assert.equal((await withdraw(bob))[0], 32n * unit / 100n);
        const last = await h.send(token, dave, 'activateToken', [id]);
        assert.equal(h.result(token, 'activateToken', last)[0], true);
        assert.equal((await withdraw(dave))[0], 32n * unit / 100n);
      } else {
        assert.equal((await withdraw(bob))[0], 0n);
      }
      const finished = await h.read(token, 'tokenData', [id]);
      assert.equal(finished[0], true);
      assert.equal(finished[1], false);
      assert.equal(finished[5], 0n);
      assert.equal(finished[6], 1n);
      assert.equal(finished[7], 0n);
      await h.reverts(token, bob, 'activateToken', [id]);
    }
  });

  test('Markets refund early cancellations even when first claimed after the deadline', async () => {
    const p = await proposal('Early cancellation');
    await h.send(governor, alice, 'stake', [p.id, true, 100n * unit]);
    await h.send(governor, bob, 'stake', [p.id, false, 100n * unit]);
    await h.reverts(governor, carol, 'cancel(address[],uint256[],bytes[],bytes32)', [p.targets, p.values, p.calldatas, p.hash]);
    await h.reverts(governor, dave, 'finalizeMarket', [p.id], 0n, 'MarketNotFinalized');
    await h.send(governor, admin, 'cancel(address[],uint256[],bytes[],bytes32)', [p.targets, p.values, p.calldatas, p.hash]);
    assert.equal((await h.read(governor, 'marketOutcome', [p.id]))[0], 3n);
    h.time += 9n * 86400n;
    const before = await balance(alice);
    await h.send(governor, alice, 'claim', [p.id]);
    assert.equal(await balance(alice) - before, 100n * unit);
    await h.send(governor, bob, 'claim', [p.id]);
    await h.reverts(governor, alice, 'claim', [p.id], 0n, 'NoStake');
    await h.reverts(governor, admin, 'burn', [p.id], 0n, 'NoOrphanedStakes');
    await h.reverts(governor, admin, 'finalizeMarket', [123], 0n, 'GovernorNonexistentProposal');
  });

  test('Late timelock cancellation cannot reopen refunds before or after winner claims', async () => {
    await h.send(governor, carol, 'lockCoins', [1000n * unit, 7n * 86400n]);
    for (const cancelFirst of [false, true]) {
      const p = await proposal(`Late cancellation ${cancelFirst}`);
      await h.send(governor, alice, 'stake', [p.id, true, 100n * unit]);
      await h.send(governor, bob, 'stake', [p.id, false, 100n * unit]);
      await finishVote(p);
      await queue(p);
      if (cancelFirst) await cancelQueued(p);
      const before = await balance(alice);
      await h.send(governor, alice, 'claim', [p.id]);
      assert.equal(await balance(alice) - before, 200n * unit);
      if (!cancelFirst) await cancelQueued(p);
      assert.equal((await h.read(governor, 'marketOutcome', [p.id]))[0], 2n);
      await h.reverts(governor, bob, 'claim', [p.id], 0n, 'StakeLostOrNothingToClaim');
      const repeat = await h.send(governor, dave, 'finalizeMarket', [p.id]);
      assert.equal(h.events(governor, repeat, 'MarketFinalized').length, 0);
    }
    assert.equal(await balance(governor), 1000n * unit);
    await h.send(governor, carol, 'unlockCoins');
    assert.equal(await balance(governor), 0n);
  });

  test('Orphan burns remain final and do not consume lock principal', async () => {
    await h.send(governor, carol, 'lockCoins', [1000n * unit, 7n * 86400n]);
    const p = await proposal('Orphaned losers');
    await h.send(governor, bob, 'stake', [p.id, false, 100n * unit]);
    await finishVote(p);
    await queue(p);
    const before = await balance(dave);
    await h.send(governor, dave, 'burn', [p.id]);
    assert.equal(await balance(dave) - before, unit);
    await cancelQueued(p);
    await h.reverts(governor, bob, 'claim', [p.id], 0n, 'StakeLostOrNothingToClaim');
    await h.reverts(governor, dave, 'burn', [p.id], 0n, 'NoOrphanedStakes');
    assert.equal(await balance(governor), 1000n * unit);
    await h.send(governor, carol, 'unlockCoins');
  });

  test('Deadline boundary, no-quorum defeat, voting replay, and lock bounds remain enforced', async () => {
    const p = await proposal('No quorum');
    await h.send(governor, bob, 'stake', [p.id, false, unit]);
    h.time = (await h.read(governor, 'proposalDeadline', [p.id]))[0] - 1n;
    await h.reverts(governor, dave, 'finalizeMarket', [p.id], 0n, 'MarketNotFinalized');
    await h.send(governor, dave, 'finalizeMarket', [p.id]);
    assert.equal((await h.read(governor, 'marketOutcome', [p.id]))[0], 1n);
    await h.send(governor, bob, 'claim', [p.id]);
    await h.reverts(governor, carol, 'lockCoins', [1n << 208n, 7n * 86400n], 0n, 'InvalidParams');
    const p2 = await proposal('Replay');
    h.time = (await h.read(governor, 'proposalSnapshot', [p2.id]))[0];
    const params = ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [0]);
    await h.send(governor, admin, 'castVoteWithReasonAndParams', [p2.id, 1, '', params]);
    await h.reverts(governor, admin, 'castVoteWithReasonAndParams', [p2.id, 1, '', params]);
  });

  let failed = 0;
  for (const { name, run } of tests) {
    h.scenario = name;
    const time = h.time, height = h.height;
    await h.vm.stateManager.checkpoint();
    try { await run(); console.log(`PASS ${name}`); }
    catch (error) { failed++; console.error(`FAIL ${name}\n${error.stack}`); }
    finally { await h.vm.stateManager.revert(); h.time = time; h.height = height; }
  }
  console.log(`Security regressions: ${tests.length - failed} passed; ${failed} failed`);
  h.writeCoverage();
  assert.equal(failed, 0);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
