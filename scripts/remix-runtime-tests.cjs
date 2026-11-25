/**
 * Node-only integration tests for the actual Remix scripts, using an EthereumJS
 * plugin/RPC adapter. Preserve observed Remix transport quirks in this adapter;
 * simplifying them can hide Desktop failures. Both ethers v5 and v6 are tested.
 * Command: npm run test:deployment. This is not a substitute for a Desktop run.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { root, compile, sourcesIn } = require('./compile.cjs');
const {
  createHarness,
  ethers,
  gasLimit,
  hexToBytes,
  bytesToHex,
  createAddressFromString,
} = require('./evm.cjs');
const {
  createRuntime,
  checkSettings,
  checkArtifact,
  checkRuntime,
  normalize,
} = require('./remix/runtime.js');
const { run } = require('./remix/workflow.js');
const { discover, executeSuite, assertionErrors } = require('./solidity-suite.cjs');

const previousCompiler = '0.8.34+commit.80d5c536';

async function main(scriptEthers) {
  console.log(`Remix plugin adapter checks using ethers ${scriptEthers.version}`);
  const sources = {
    ...sourcesIn('contracts'),
    ...sourcesIn('tests', (file) => file === 'RunnerFailureProbe.sol'),
  };
  const contracts = compile(sources);
  const { compiler } = JSON.parse(contracts['contracts/DigilCoin.sol'].DigilCoin.metadata);
  const currentCompilerFile = `soljson-v${compiler.version}.js`;
  const h = await createHarness(contracts);
  const config = JSON.parse(fs.readFileSync(path.join(root, 'remix.config.json'), 'utf8'));
  let provider = 'vm-osaka',
    result,
    broadcasts = 0,
    interruptAt = 0,
    badSource = false,
    badDependency = false,
    offline = false;
  let compilationMode = 'ok',
    compilerVersion = currentCompilerFile,
    changeInput = () => {},
    stateReads = 0;
  let proofFault = '';
  const files = new Map(),
    receipts = new Map(),
    transactions = new Map(),
    executions = new Map(),
    logs = [];
  const disk = (file) => fs.readFileSync(path.join(root, file), 'utf8');
  const listeners = new Map();
  const on = (plugin, event, callback) => listeners.set(`${plugin}.${event}`, callback);
  const off = (plugin, event) => listeners.delete(`${plugin}.${event}`);
  // Callbacks stay in the script. Only event payloads and RPC arguments/results
  // cross the structured-clone boundary used by the actual Remix iframe bridge.
  const emit = (event, ...args) => listeners.get(`solidity.${event}`)?.(...structuredClone(args));
  const dispatch = async (plugin, method, ...args) => {
    if (plugin === 'fileManager') {
      if (method === 'readFile') return files.has(args[0]) ? files.get(args[0]) : disk(args[0]);
      if (method === 'writeFile') {
        files.set(args[0], args[1]);
        return;
      }
      if (method === 'exists') return files.has(args[0]) || fs.existsSync(path.join(root, args[0]));
    }
    if (plugin === 'solidity') {
      if (method === 'getCompilerState') {
        stateReads++;
        return {
          currentVersion: compilerVersion,
          useFileConfiguration: true,
          configFileContent: config['solidity-compiler'],
          compileJSON: function (source, timeStamp) {},
        };
      }
      if (method === 'getCurrentCompilerConfig')
        return { currentVersion: compilerVersion, evmVersion: 'osaka', optimize: false, runs: 200 };
      if (method === 'compile') {
        if (compilationMode === 'throw') throw new Error('compiler unavailable');
        const resolved = { ...sources, [args[0]]: { content: files.get(args[0]) } };
        resolved['@openzeppelin/contracts/access/AccessControl.sol'] = {
          content: badDependency
            ? 'wrong dependency'
            : disk('.deps/npm/@openzeppelin/contracts@5.6.1/access/AccessControl.sol'),
        };
        if (badSource) resolved['contracts/DigilCoin.sol'] = { content: 'stale source' };
        result = { data: { contracts }, source: { sources: resolved, target: args[0] } };
        const input = {
          ...structuredClone(config['solidity-compiler']),
          sources: structuredClone(resolved),
        };
        input.settings.remappings = [];
        changeInput(input);
        // Cached results remain available, but are not proof of fresh settings.
        if (compilationMode === 'missing-event') return true;
        const eventSource = structuredClone(result.source);
        if (compilationMode === 'stale-event')
          eventSource.sources[args[0]].content = 'previous compilation';
        const event = compilationMode === 'failure' ? 'compilationFailed' : 'compilationFinished';
        const eventInput = compilationMode === 'missing-input' ? undefined : JSON.stringify(input);
        const eventVersion =
          compilationMode === 'wrong-version' ? previousCompiler : compilerVersion;
        // An unrelated compilation must not satisfy this run's freshness check.
        emit(
          'compilationFinished',
          'contracts/NFT.sol',
          result.source,
          'soljson',
          result.data,
          '{}',
          compilerVersion
        );
        emit(event, args[0], eventSource, 'soljson', result.data, eventInput, eventVersion);
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
  const call = async (...args) => structuredClone(await dispatch(...structuredClone(args)));
  const hex = (value) => '0x' + BigInt(value).toString(16);
  const rpc = async (method, params) => {
    if (offline) throw new Error('provider disconnected');
    if (method === 'eth_accounts') return h.users.slice(0, 10).map((user) => user.address);
    if (method === 'eth_chainId') return '0x1';
    if (method === 'eth_getBlockByNumber') return { timestamp: hex(h.time), number: hex(h.height) };
    if (method === 'evm_setNextBlockTimestamp') return null; // Match Remix's no-op.
    if (method === 'evm_mine') {
      h.time++;
      h.height++;
      return null;
    }
    if (method === 'eth_getTransactionCount')
      return hex((await h.vm.stateManager.getAccount(createAddressFromString(params[0]))).nonce);
    if (method === 'eth_getTransactionByHash') return transactions.get(params[0]) || null;
    if (method === 'eth_getTransactionReceipt') {
      if (interruptAt && broadcasts === interruptAt) {
        interruptAt = 0;
        throw new Error('simulated interruption after broadcast');
      }
      if (proofFault === 'missing-receipt') return null;
      return receipts.get(params[0]) || null;
    }
    if (method === 'eth_getExecutionResultFromSimulator') {
      if (proofFault === 'missing-execution') return undefined;
      if (proofFault === 'transport') throw new Error('revert RPC unavailable');
      const execution = executions.get(params[0]);
      if (proofFault === 'out-of-gas')
        return { ...execution, exceptionError: { error: 'out of gas', errorType: 'EvmError' } };
      if (proofFault === 'invalid-opcode')
        return { ...execution, exceptionError: { error: 'invalid opcode', errorType: 'EvmError' } };
      return execution;
    }
    if (method === 'eth_getCode')
      return bytesToHex(await h.vm.stateManager.getCode(createAddressFromString(params[0])));
    if (method === 'eth_getBalance')
      return hex((await h.vm.stateManager.getAccount(createAddressFromString(params[0]))).balance);
    if (method === 'eth_getLogs') {
      const filter = params[0];
      return logs.filter((log) => {
        // Remix LogsManager reads topics.length without defaulting this field.
        for (let i = 0; i < filter.topics.length; i++) {
          const topic = filter.topics[i];
          if (
            topic &&
            !(Array.isArray(topic) ? topic.includes(log.topics[i]) : topic === log.topics[i])
          )
            return false;
        }
        return log.address.toLowerCase() === filter.address.toLowerCase();
      });
    }
    if (method === 'eth_sendTransaction') {
      const tx = params[0];
      assert.ok(BigInt(tx.gas) <= gasLimit);
      const user = h.users.find((user) => user.address.toLowerCase() === tx.from.toLowerCase());
      assert.ok(user, 'only deterministic test accounts may send transactions');
      const executed = await h.tx(user, tx.to, tx.data, BigInt(tx.value || 0), true);
      const hash = ethers.id(`${h.height}:${tx.from}:${tx.data}`);
      const txLogs = (executed.execResult.logs || []).map((log) => ({
        address: bytesToHex(log[0]),
        topics: log[1].map(bytesToHex),
        data: bytesToHex(log[2]),
      }));
      const receipt = {
        transactionHash: hash,
        blockHash: ethers.id('block-' + h.height),
        status: executed.execResult.exceptionError ? '0x0' : '0x1',
        contractAddress: executed.createdAddress?.toString() || null,
        gasUsed: hex(executed.totalGasSpent),
        logs: txLogs,
      };
      transactions.set(hash, { ...tx, input: tx.data, to: tx.to || null });
      receipts.set(hash, receipt);
      executions.set(hash, {
        exceptionError: executed.execResult.exceptionError && {
          error: executed.execResult.exceptionError.error,
          errorType: executed.execResult.exceptionError.errorType,
        },
        executionGasUsed: executed.execResult.executionGasUsed,
        returnValue: bytesToHex(executed.execResult.returnValue),
      });
      logs.push(...txLogs);
      broadcasts++;
      return hash;
    }
    if (method === 'eth_call') {
      const tx = params[0];
      await h.vm.stateManager.checkpoint();
      try {
        await h.vm.evm.journal.cleanup();
        h.vm.stateManager.originalStorageCache.clear();
        // Remix discards call value and returns raw bytes even when execution
        // reverts. Only mined receipts + simulator execution records prove failure.
        const executed = await h.vm.evm.runCall({
          to: createAddressFromString(tx.to),
          caller: createAddressFromString(tx.from),
          data: hexToBytes(tx.data),
          value: 0n,
          gasLimit,
          block: h.block(),
        });
        return bytesToHex(executed.execResult.returnValue);
      } finally {
        await h.vm.stateManager.revert();
      }
    }
    throw new Error(`Unexpected RPC method ${method}`);
  };

  assert.equal(normalize(18), 18n, 'ethers v5 small integer normalization');
  assert.equal(normalize({ _isBigNumber: true, toString: () => '123' }), 123n);
  await assert.rejects(
    call('solidity', 'getCompilerState'),
    { name: 'DataCloneError' },
    'reproduce the Desktop postMessage failure'
  );
  checkSettings(JSON.stringify(config['solidity-compiler']), compilerVersion, config);
  assert.throws(() => checkSettings(undefined, compilerVersion, config), /Missing compiler input/);
  assert.throws(() => checkSettings('null', compilerVersion, config), /Invalid compiler input/);
  const artifact = contracts['contracts/DigilToken.sol'].DigilToken;
  const oversized = structuredClone(artifact);
  oversized.evm.deployedBytecode.object = '00'.repeat(24577);
  assert.throws(() => checkArtifact(oversized), /Runtime size/);
  assert.throws(() => checkArtifact(artifact, '0x' + '00'.repeat(49152)), /Creation input/);
  assert.throws(() => checkRuntime(artifact, '0x'), /Missing/);
  assert.throws(
    () =>
      checkRuntime(artifact, '0x' + '00'.repeat(artifact.evm.deployedBytecode.object.length / 2)),
    /does not match/
  );
  console.log('PASS compiler, ethers compatibility, code size and creation-input guards');

  const options = { ethers: scriptEthers, call, on, off, log: () => {}, sleep: async () => {} };
  provider = 'injected-MetaMask';
  await assert.rejects(createRuntime(options), /Only Remix VM/);
  provider = 'vm-mainnet-fork';
  await assert.rejects(createRuntime(options), /Osaka/);
  provider = 'vm-osaka';
  const runtime = await createRuntime(options);
  compilerVersion = `soljson-v${previousCompiler}.js`;
  await assert.rejects(runtime.compile(), /Select Solidity/);
  compilerVersion = currentCompilerFile;
  const settingsMutations = [
    (input) => {
      input.settings.optimizer = { enabled: false, runs: 200 };
    },
    (input) => {
      input.settings.optimizer.runs = 200;
    },
    (input) => {
      input.settings.viaIR = true;
    },
    (input) => {
      input.settings.optimizer.details.yul = true;
    },
    (input) => {
      input.settings.evmVersion = 'prague';
    },
    (input) => {
      input.settings.debug.revertStrings = 'default';
    },
    (input) => {
      input.settings.metadata.bytecodeHash = 'ipfs';
    },
    (input) => {
      delete input.settings.outputSelection;
    },
    (input) => {
      input.settings.remappings = ['@openzeppelin/=other/'];
    },
  ];
  for (const mutate of settingsMutations) {
    changeInput = mutate;
    await assert.rejects(runtime.compile(), /settings differ/);
    assert.equal(listeners.size, 0, 'settings rejection must clean up event listeners');
  }
  changeInput = (input) => {
    input.sources['contracts/DigilCoin.sol'].content = 'different input';
  };
  await assert.rejects(runtime.compile(), /input sources differ/);
  changeInput = () => {};
  for (const [mode, expected] of [
    ['missing-event', /No fresh compilation event/],
    ['stale-event', /No fresh compilation event/],
    ['missing-input', /Missing compiler input/],
    ['wrong-version', /Select Solidity/],
    ['failure', /Compilation failed/],
    ['throw', /compiler unavailable/],
  ]) {
    compilationMode = mode;
    await assert.rejects(runtime.compile(), expected);
    assert.equal(listeners.size, 0, `${mode} must clean up event listeners`);
  }
  compilationMode = 'ok';
  const originalMetadata = artifact.metadata;
  const staleMetadata = JSON.parse(originalMetadata);
  staleMetadata.compiler.version = previousCompiler;
  artifact.metadata = JSON.stringify(staleMetadata);
  await assert.rejects(runtime.compile(), /Unexpected artifact compiler/);
  artifact.metadata = originalMetadata;
  assert.equal(broadcasts, 0, 'compiler validation failures must not deploy anything');
  console.log(
    'PASS Desktop structured-clone regression, exact compilation-input checks and compiler event cleanup'
  );
  badSource = true;
  await assert.rejects(runtime.compile(), /source mismatch/);
  badSource = false;
  badDependency = true;
  await assert.rejects(runtime.compile(), /Resolved source mismatch/);
  badDependency = false;
  await runtime.compile();
  assert.equal(
    (await runtime.capabilities()).clock,
    false,
    'no-op RPC must not be considered time control'
  );
  const remix = { call, on, off };
  const preflightLog = [];
  await run('preflight', { ethers: scriptEthers, remix, log: (line) => preflightLog.push(line) });
  assert.ok(preflightLog.some((line) => line.startsWith('PASS deployment preflight')));
  assert.equal(broadcasts, 0, 'preflight sends no deployment transactions');
  assert.equal(listeners.size, 0, 'successful compilation must clean up event listeners');
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
  assert.equal(
    broadcasts,
    9,
    'resume uses the existing two deployments and sends only remaining transactions'
  );
  await assert.rejects(
    runtime.h.rpc('eth_getLogs', [
      { address: fixture.coin.address, fromBlock: '0x0', toBlock: 'latest' },
    ]),
    /Cannot read properties of undefined \(reading 'length'\)/,
    'reproduce Remix Desktop missing-topics failure after logs exist'
  );
  await runtime.verifyRecorded();
  offline = true;
  await assert.rejects(
    runtime.h.reverts(fixture.coin, runtime.h.users[1], 'mint', [h.users[1].address, 1]),
    /not proof/
  );
  offline = false;
  await runtime.deployRecorded();
  assert.equal(broadcasts, 9, 'repeat deploy is idempotent');
  console.log(
    'PASS complete deployment, interrupted receipt recovery, verification and idempotent rerun'
  );

  interruptAt = broadcasts + 2;
  await assert.rejects(
    run('seed-demo', { ethers: scriptEthers, remix, log: () => {} }),
    /simulated interruption/
  );
  await assert.rejects(runtime.verifyRecorded(), /incomplete operation/);
  await run('seed-demo', { ethers: scriptEthers, remix, log: () => {} });
  const afterSeed = broadcasts;
  await run('seed-demo', { ethers: scriptEthers, remix, log: () => {} });
  assert.equal(broadcasts, afterSeed, 'demo seed does not mint twice');
  await assert.rejects(
    run('handoff', { ethers: scriptEthers, remix, log: () => {} }),
    /Handoff blocked/
  );
  assert.equal(broadcasts, afterSeed, 'blocked handoff must send no transactions');
  console.log('PASS idempotent demo seed and zero-transaction handoff blocker');

  await runtime.h.send(fixture.coin, runtime.h.users[0], 'grantRole', [
    ethers.id('MINTER_ROLE'),
    h.users[3].address,
  ]);
  await assert.rejects(runtime.verifyRecorded(), /Unexpected role holders/);
  await runtime.h.send(fixture.coin, runtime.h.users[0], 'revokeRole', [
    ethers.id('MINTER_ROLE'),
    h.users[3].address,
  ]);
  await runtime.verifyRecorded();
  const coinLogs = await runtime.h.rpc('eth_getLogs', [
    { address: fixture.coin.address, fromBlock: '0x0', toBlock: 'latest', topics: [] },
  ]);
  const roleEvents = coinLogs.map((entry) => fixture.coin.iface.parseLog(entry)?.name);
  assert.ok(
    roleEvents.includes('RoleGranted') && roleEvents.includes('RoleRevoked'),
    'empty topics must preserve both role-event types'
  );
  console.log('PASS Remix log-filter compatibility and grant/revoke history verification');
  const saved = JSON.parse(files.get('.remix/deployment.json'));
  const corrupt = structuredClone(saved);
  corrupt.addresses.token = fixture.coin.address;
  files.set('.remix/deployment.json', JSON.stringify(corrupt));
  await assert.rejects(runtime.verifyRecorded(), /Address record mismatch/);
  files.set('.remix/deployment.json', JSON.stringify(saved));
  receipts.delete(saved.steps.DigilCoin.transactionHash);
  await assert.rejects(runtime.verifyRecorded(), /Receipt unavailable/);
  console.log('PASS unexpected-role, tampered-address and reset-VM detection');
  assert.throws(() => require('./functional-scenarios.js').eq(1, 2), /expected 2, got 1/);
  console.log('PASS deliberate assertion failure is detected');

  const probe = await h.deploy('RunnerFailureProbe', [], false, 'tests/RunnerFailureProbe.sol');
  const revertedCall = await runtime.h.rpc('eth_call', [
    {
      from: h.users[1].address,
      to: fixture.coin.address,
      data: fixture.coin.iface.encodeFunctionData('mint', [h.users[1].address, 1]),
    },
    'latest',
  ]);
  assert.equal(
    fixture.coin.iface.parseError(revertedCall).name,
    'AccessControlUnauthorizedAccount',
    'Remix returns revert bytes without throwing'
  );
  await runtime.h.reverts(
    fixture.coin,
    runtime.h.users[1],
    'mint',
    [h.users[1].address, 1],
    0n,
    'AccessControlUnauthorizedAccount'
  );
  await assert.rejects(
    runtime.h.reverts(
      fixture.coin,
      runtime.h.users[1],
      'mint',
      [h.users[1].address, 1],
      0n,
      'OwnableUnauthorizedAccount'
    ),
    /could not confirm/
  );
  await runtime.h.reverts(probe, runtime.h.users[0], 'revertingCall');
  await assert.rejects(
    runtime.h.reverts(probe, runtime.h.users[0], 'falseReturn'),
    /should revert/
  );
  await assert.rejects(
    runtime.h.reverts(fixture.coin, runtime.h.users[0], 'mint', [h.users[1].address, 0]),
    /should revert/
  );
  const beforeBalance = (await runtime.h.read(fixture.coin, 'balanceOf', [h.users[1].address]))[0];
  await runtime.h.reverts(fixture.coin, runtime.h.users[0], 'mint', [h.users[1].address, 1], 1n);
  assert.equal(
    [...transactions.values()].at(-1).value,
    '0x1',
    'negative tests must retain their supplied ETH value'
  );
  assert.equal(
    (await runtime.h.read(fixture.coin, 'balanceOf', [h.users[1].address]))[0],
    beforeBalance,
    'failed nonpayable call must not mint'
  );
  for (const fault of [
    'missing-receipt',
    'missing-execution',
    'transport',
    'out-of-gas',
    'invalid-opcode',
  ]) {
    proofFault = fault;
    await assert.rejects(
      runtime.h.reverts(fixture.coin, runtime.h.users[1], 'mint', [h.users[1].address, 1]),
      /not proof|could not confirm/
    );
  }
  proofFault = '';
  console.log(
    'PASS receipt-backed revert proofs, empty/custom errors, ETH value and rejection of false positives'
  );
  const assertInterface = new ethers.Interface(
    (contracts['remix_tests.sol'] || contracts['tests/remix_tests.sol']).Assert.abi
  );
  for (const [name, expected] of [
    ['falseAssertion', 'deliberately failing assertion'],
    ['falseReturn', 'Test returned false'],
    ['revertingCall', 'revert'],
  ]) {
    const executed = await h.send(probe, h.users[0], name, [], 0n, true);
    const errors = assertionErrors(
      executed,
      { name, returnsBool: name === 'falseReturn' },
      probe.iface,
      assertInterface,
      bytesToHex
    );
    assert.ok(
      errors.some((error) => error.includes(expected)),
      `${name} must fail the Solidity runner`
    );
  }
  const methods = discover(
    'function beforeAll() public {}\n/// #sender: account-2\n/// #value: 7\nfunction testFirst() public {}\nfunction afterAll() public {}',
    ['beforeAll', 'testFirst', 'afterAll'].map((name) => ({
      type: 'function',
      name,
      inputs: [],
      outputs: [],
    }))
  );
  assert.equal(methods[1].sender, 2);
  assert.equal(methods[1].value, 7n);
  const order = [];
  await executeSuite(methods, async (method) => {
    order.push(method.name);
    return method.name !== 'beforeAll';
  });
  assert.deepEqual(order, ['beforeAll', 'afterAll'], 'failed setup cannot run the behavioral test');
  console.log(
    'PASS Solidity assertion events, false returns, reverts, annotations and failed setup handling'
  );
  await run('test', { ethers: scriptEthers, remix, log: () => {} });
  const smoke = JSON.parse(files.get('.remix/smoke-results.json'));
  assert.equal(smoke.results.length, 14);
  assert.ok(smoke.results.every((result) => result.passed));
  assert.ok(
    smoke.omitted.includes('full governance handoff'),
    'subset must explicitly disclose omitted coverage'
  );
  assert.equal(
    stateReads,
    1,
    'only the deliberate reproduction may request non-serializable compiler state'
  );
  assert.equal(listeners.size, 0);
  console.log('PASS all 14 shared scenarios through the Remix RPC adapter (not a browser UI test)');
}
(async () => {
  await main(ethers);
  await main(require('ethers-v5'));
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
