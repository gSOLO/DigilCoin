// Exercise the actual Remix workflow through a plugin API adapter backed by the
// production-limit EthereumJS VM. This is not a substitute for a Remix UI run.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { root, compile, sourcesIn } = require('./compile.cjs');
const { createHarness, ethers, gasLimit, hexToBytes, bytesToHex, createAddressFromString } = require('./evm.cjs');
const { createRuntime, checkSettings, checkArtifact, checkRuntime, normalize } = require('./remix/runtime.js');
const { run } = require('./remix/workflow.js');
const { discover, executeSuite, assertionErrors } = require('./solidity-suite.cjs');

async function main(scriptEthers) {
  console.log(`Remix plugin adapter checks using ethers ${scriptEthers.version}`);
  const sources = { ...sourcesIn('contracts'), ...sourcesIn('tests', file => file === 'RunnerFailureProbe.sol') };
  const contracts = compile(sources);
  const h = await createHarness(contracts);
  const config = JSON.parse(fs.readFileSync(path.join(root, 'remix.config.json'), 'utf8'));
  let provider = 'vm-osaka', result, broadcasts = 0, interruptAt = 0, badSource = false, badDependency = false, offline = false;
  const files = new Map(), receipts = new Map(), transactions = new Map(), logs = [];
  const disk = file => fs.readFileSync(path.join(root, file), 'utf8');
  const state = () => ({ currentVersion: 'soljson-v0.8.34+commit.80d5c536.js', useFileConfiguration: true,
    configFileContent: config['solidity-compiler'] });
  const call = async (plugin, method, ...args) => {
    if (plugin === 'fileManager') {
      if (method === 'readFile') return files.has(args[0]) ? files.get(args[0]) : disk(args[0]);
      if (method === 'writeFile') { files.set(args[0], args[1]); return; }
      if (method === 'exists') return files.has(args[0]) || fs.existsSync(path.join(root, args[0]));
    }
    if (plugin === 'solidity') {
      if (method === 'getCompilerState') return state();
      if (method === 'compile') {
        const resolved = { ...sources, [args[0]]: { content: files.get(args[0]) } };
        resolved['@openzeppelin/contracts/access/AccessControl.sol'] = { content: badDependency ? 'wrong dependency' :
          disk('.deps/npm/@openzeppelin/contracts@5.6.1/access/AccessControl.sol') };
        if (badSource) resolved['contracts/DigilCoin.sol'] = { content: 'stale source' };
        result = { data: { contracts }, source: { sources: resolved } };
        return true;
      }
      if (method === 'getCompilationResult') return result;
    }
    if (plugin === 'blockchain') {
      if (method === 'isVM') return provider.startsWith('vm-');
      if (method === 'getProvider') return provider;
      if (method === 'sendRpc') return rpc(args[0], args[1]);
    }
    throw new Error(`Unexpected plugin API: ${plugin}.${method}`);
  };
  const hex = value => '0x' + BigInt(value).toString(16);
  const rpc = async (method, params) => {
    if (method === 'eth_accounts') return h.users.slice(0, 10).map(user => user.address);
    if (method === 'eth_chainId') return '0x1';
    if (method === 'eth_getBlockByNumber') return { timestamp: hex(h.time), number: hex(h.height) };
    if (method === 'evm_setNextBlockTimestamp') return null; // Match Remix's no-op.
    if (method === 'evm_mine') { h.time++; h.height++; return null; }
    if (method === 'eth_getTransactionCount') return hex((await h.vm.stateManager.getAccount(createAddressFromString(params[0]))).nonce);
    if (method === 'eth_getTransactionByHash') return transactions.get(params[0]) || null;
    if (method === 'eth_getTransactionReceipt') {
      if (interruptAt && broadcasts === interruptAt) { interruptAt = 0; throw new Error('simulated interruption after broadcast'); }
      return receipts.get(params[0]) || null;
    }
    if (method === 'eth_getCode') return bytesToHex(await h.vm.stateManager.getCode(createAddressFromString(params[0])));
    if (method === 'eth_getBalance') return hex((await h.vm.stateManager.getAccount(createAddressFromString(params[0]))).balance);
    if (method === 'eth_getLogs') return logs.filter(log => log.address.toLowerCase() === params[0].address.toLowerCase());
    if (method === 'eth_sendTransaction') {
      const tx = params[0];
      assert.ok(BigInt(tx.gas) <= gasLimit);
      const user = h.users.find(user => user.address.toLowerCase() === tx.from.toLowerCase());
      assert.ok(user, 'only deterministic test accounts may send transactions');
      const executed = await h.tx(user, tx.to, tx.data, BigInt(tx.value || 0), true);
      const hash = ethers.id(`${h.height}:${tx.from}:${tx.data}`);
      const txLogs = (executed.execResult.logs || []).map(log => ({ address: bytesToHex(log[0]), topics: log[1].map(bytesToHex), data: bytesToHex(log[2]) }));
      const receipt = { transactionHash: hash, blockHash: ethers.id('block-' + h.height), status: executed.execResult.exceptionError ? '0x0' : '0x1',
        contractAddress: executed.createdAddress?.toString() || null, gasUsed: hex(executed.totalGasSpent), logs: txLogs };
      transactions.set(hash, { ...tx, input: tx.data, to: tx.to || null });
      receipts.set(hash, receipt);
      logs.push(...txLogs);
      broadcasts++;
      return hash;
    }
    if (method === 'eth_call') {
      if (offline) throw new Error('provider disconnected');
      const tx = params[0];
      await h.vm.stateManager.checkpoint();
      try {
        await h.vm.evm.journal.cleanup();
        h.vm.stateManager.originalStorageCache.clear();
        const executed = await h.vm.evm.runCall({ to: createAddressFromString(tx.to), caller: createAddressFromString(tx.from),
          data: hexToBytes(tx.data), value: BigInt(tx.value || 0), gasLimit, block: h.block() });
        if (executed.execResult.exceptionError) throw Object.assign(new Error('execution reverted'), { data: bytesToHex(executed.execResult.returnValue) });
        return bytesToHex(executed.execResult.returnValue);
      } finally { await h.vm.stateManager.revert(); }
    }
    throw new Error(`Unexpected RPC method ${method}`);
  };

  assert.equal(normalize(18), 18n, 'ethers v5 small integer normalization');
  assert.equal(normalize({ _isBigNumber: true, toString: () => '123' }), 123n);
  assert.throws(() => checkSettings({ ...state(), useFileConfiguration: false }, config), /configuration file/);
  const changed = structuredClone(state()); changed.configFileContent.settings.optimizer.runs = 200;
  assert.throws(() => checkSettings(changed, config), /differ/);
  changed.configFileContent.settings.viaIR = true;
  assert.throws(() => checkSettings(changed, config), /differ/);
  const artifact = contracts['contracts/DigilToken.sol'].DigilToken;
  const oversized = structuredClone(artifact); oversized.evm.deployedBytecode.object = '00'.repeat(24577);
  assert.throws(() => checkArtifact(oversized), /Runtime size/);
  assert.throws(() => checkArtifact(artifact, '0x' + '00'.repeat(49152)), /Creation input/);
  assert.throws(() => checkRuntime(artifact, '0x'), /Missing/);
  assert.throws(() => checkRuntime(artifact, '0x' + '00'.repeat(artifact.evm.deployedBytecode.object.length / 2)), /does not match/);
  console.log('PASS compiler, ethers compatibility, code size and creation-input guards');

  const options = { ethers: scriptEthers, call, log: () => {}, sleep: async () => {} };
  provider = 'injected-MetaMask';
  await assert.rejects(createRuntime(options), /Only Remix VM/);
  provider = 'vm-mainnet-fork';
  await assert.rejects(createRuntime(options), /Osaka/);
  provider = 'vm-osaka';
  const runtime = await createRuntime(options);
  badSource = true;
  await assert.rejects(runtime.compile(), /source mismatch/);
  badSource = false;
  badDependency = true;
  await assert.rejects(runtime.compile(), /Resolved source mismatch/);
  badDependency = false;
  await runtime.compile();
  assert.equal((await runtime.capabilities()).clock, false, 'no-op RPC must not be considered time control');
  console.log('PASS provider allowlist, stale-source rejection and no-op clock detection');

  interruptAt = 2;
  await assert.rejects(runtime.deployRecorded(), /simulated interruption/);
  const pending = JSON.parse(files.get('.remix/deployment.json'));
  assert.ok(pending.pending.hash);
  const ambiguous = structuredClone(pending);
  delete ambiguous.pending.hash;
  files.set('.remix/deployment.json', JSON.stringify(ambiguous));
  await assert.rejects(runtime.deployRecorded(), /Ambiguous broadcast/);
  assert.equal(broadcasts, 2, 'ambiguous recovery must not send a duplicate transaction');
  files.set('.remix/deployment.json', JSON.stringify(pending));
  const fixture = await runtime.deployRecorded();
  assert.equal(broadcasts, 9, 'resume uses the existing two deployments and sends only remaining transactions');
  await runtime.verifyRecorded();
  offline = true;
  await assert.rejects(runtime.h.reverts(fixture.coin, runtime.h.users[1], 'mint', [h.users[1].address, 1]), /not proof/);
  offline = false;
  await runtime.deployRecorded();
  assert.equal(broadcasts, 9, 'repeat deploy is idempotent');
  console.log('PASS complete deployment, interrupted receipt recovery, verification and idempotent rerun');

  const remix = { call };
  interruptAt = broadcasts + 2;
  await assert.rejects(run('seed-demo', { ethers: scriptEthers, remix, log: () => {} }), /simulated interruption/);
  await assert.rejects(runtime.verifyRecorded(), /incomplete operation/);
  await run('seed-demo', { ethers: scriptEthers, remix, log: () => {} });
  const afterSeed = broadcasts;
  await run('seed-demo', { ethers: scriptEthers, remix, log: () => {} });
  assert.equal(broadcasts, afterSeed, 'demo seed does not mint twice');
  await assert.rejects(run('handoff', { ethers: scriptEthers, remix, log: () => {} }), /Handoff blocked/);
  assert.equal(broadcasts, afterSeed, 'blocked handoff must send no transactions');
  console.log('PASS idempotent demo seed and zero-transaction handoff blocker');

  await h.send({ ...fixture.coin }, adminUser(h), 'grantRole', [ethers.id('MINTER_ROLE'), h.users[3].address]);
  // This direct harness transaction is outside the RPC log adapter. Include its
  // real role-change event to exercise exact-holder verification.
  logs.push({ address: fixture.coin.address, ...fixture.coin.iface.encodeEventLog(fixture.coin.iface.getEvent('RoleGranted'),
    [ethers.id('MINTER_ROLE'), h.users[3].address, h.users[0].address]) });
  await assert.rejects(runtime.verifyRecorded(), /Unexpected role holders/);
  logs.pop();
  await h.send({ ...fixture.coin }, adminUser(h), 'revokeRole', [ethers.id('MINTER_ROLE'), h.users[3].address]);
  const saved = JSON.parse(files.get('.remix/deployment.json'));
  const corrupt = structuredClone(saved); corrupt.addresses.token = fixture.coin.address;
  files.set('.remix/deployment.json', JSON.stringify(corrupt));
  await assert.rejects(runtime.verifyRecorded(), /Address record mismatch/);
  files.set('.remix/deployment.json', JSON.stringify(saved));
  receipts.delete(saved.steps.DigilCoin.transactionHash);
  await assert.rejects(runtime.verifyRecorded(), /Receipt unavailable/);
  console.log('PASS unexpected-role, tampered-address and reset-VM detection');
  assert.throws(() => require('./functional-scenarios.js').eq(1, 2), /expected 2, got 1/);
  console.log('PASS deliberate assertion failure is detected');

  const probe = await h.deploy('RunnerFailureProbe', [], false, 'tests/RunnerFailureProbe.sol');
  const assertInterface = new ethers.Interface((contracts['remix_tests.sol'] || contracts['tests/remix_tests.sol']).Assert.abi);
  for (const [name, expected] of [['falseAssertion', 'deliberately failing assertion'], ['falseReturn', 'Test returned false'], ['revertingCall', 'revert']]) {
    const executed = await h.send(probe, h.users[0], name, [], 0n, true);
    const errors = assertionErrors(executed, { name, returnsBool: name === 'falseReturn' }, probe.iface, assertInterface, bytesToHex);
    assert.ok(errors.some(error => error.includes(expected)), `${name} must fail the Solidity runner`);
  }
  const methods = discover('function beforeAll() public {}\n/// #sender: account-2\n/// #value: 7\nfunction testFirst() public {}\nfunction afterAll() public {}',
    ['beforeAll', 'testFirst', 'afterAll'].map(name => ({ type: 'function', name, inputs: [], outputs: [] })));
  assert.equal(methods[1].sender, 2);
  assert.equal(methods[1].value, 7n);
  const order = [];
  await executeSuite(methods, async method => { order.push(method.name); return method.name !== 'beforeAll'; });
  assert.deepEqual(order, ['beforeAll', 'afterAll'], 'failed setup cannot run the behavioral test');
  console.log('PASS Solidity assertion events, false returns, reverts, annotations and failed setup handling');
  await run('test', { ethers: scriptEthers, remix, log: () => {} });
  const smoke = JSON.parse(files.get('.remix/smoke-results.json'));
  assert.equal(smoke.results.length, 14);
  assert.ok(smoke.results.every(result => result.passed));
  assert.ok(smoke.omitted.includes('full governance handoff'), 'subset must explicitly disclose omitted coverage');
  console.log('PASS all 14 shared scenarios through the Remix RPC adapter (not a browser UI test)');
}
const adminUser = h => h.users[0];
(async () => {
  await main(ethers);
  await main(require('ethers-v5'));
})().catch(error => { console.error(error); process.exitCode = 1; });
