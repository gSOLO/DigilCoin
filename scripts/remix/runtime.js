/**
 * Remix VM adapter: compiler proof, guarded RPC, transaction journal and fixtures.
 * Loaded by workflow.js through the workspace file manager, or required by Node
 * adapter tests. Keep this module free of Node-only imports and wallet signing.
 * Compiler/provider/size/revert checks are validation boundaries, not preferences.
 */
const NAMES = ['DigilCoin', 'DigilToken', 'DigilGovernor', 'DigilTimelock'];
const GAS = 16777216n;
const VERSION = '0.8.34+commit.80d5c536';
const RECORD = '.remix/deployment.json';

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object')
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])])
    );
  return typeof value === 'bigint' ? value.toString() : value;
}
const json = (value) => JSON.stringify(canonical(value));
const hex = (value) => '0x' + BigInt(value).toString(16);
const equalAddress = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

function checkVersion(version) {
  invariant(String(version).includes(VERSION), `Select Solidity ${VERSION}.`);
}

function checkSettings(input, version, config) {
  checkVersion(version);
  invariant(
    typeof input === 'string' && input.length > 0,
    'Missing compiler input from Remix compilation event. No deployment was attempted.'
  );
  const actual = JSON.parse(input);
  invariant(
    actual && typeof actual === 'object' && !Array.isArray(actual),
    'Invalid compiler input'
  );
  delete actual.sources;
  // Remix inserts an empty remappings list even when none was requested.
  if (actual.settings?.remappings?.length === 0) delete actual.settings.remappings;
  invariant(
    json(actual) === json(config['solidity-compiler']),
    'Effective compiler settings differ from remix.config.json. Select Use configuration file; GUI optimizer defaults are not accepted. No deployment was attempted.'
  );
}

function checkArtifact(artifact, argsData = '0x') {
  invariant(artifact?.evm?.bytecode?.object, 'Missing compiler artifact');
  const runtime = artifact.evm.deployedBytecode.object;
  const creation = artifact.evm.bytecode.object;
  invariant(/^[0-9a-f]*$/i.test(creation), 'Unlinked bytecode is not deployable by this runner');
  invariant(runtime.length / 2 <= 24576, `Runtime size ${runtime.length / 2} exceeds 24576 bytes`);
  invariant(
    (creation.length + argsData.length - 2) / 2 <= 49152,
    'Creation input including constructor arguments exceeds 49152 bytes'
  );
}

function checkRuntime(artifact, code) {
  let expected = artifact.evm.deployedBytecode.object.toLowerCase();
  let actual = code.replace(/^0x/, '').toLowerCase();
  invariant(
    actual.length > 0 && actual.length === expected.length,
    'Missing or incorrectly sized deployed code; the VM may have been reset'
  );
  // Immutables are patched by the constructor. Verify all other runtime bytes,
  // then check constructor-dependent relationships through the contract API.
  for (const refs of Object.values(artifact.evm.deployedBytecode.immutableReferences || {})) {
    for (const { start, length } of refs) {
      expected =
        expected.slice(0, start * 2) +
        '0'.repeat(length * 2) +
        expected.slice((start + length) * 2);
      actual =
        actual.slice(0, start * 2) + '0'.repeat(length * 2) + actual.slice((start + length) * 2);
    }
  }
  invariant(actual === expected, 'Deployed code does not match the current artifact');
}

function normalize(value) {
  if (typeof value === 'number') return BigInt(value);
  if (value?._isBigNumber) return BigInt(value.toString());
  if (!Array.isArray(value)) return value;
  const result = Array.from(value, normalize);
  for (const key of Object.keys(value).filter((key) => !/^\d+$/.test(key)))
    result[key] = normalize(value[key]);
  return result;
}

/**
 * Bind ethers v5/v6 plus Remix call/on/off methods to one VM/workspace run.
 * Compile before using h or deployment methods. h is the portable scenario API;
 * deployRecorded/verifyRecorded additionally enforce the persistent journal.
 * sleep is injectable so adapter failure/recovery tests need not wait in real time.
 */
async function createRuntime({
  ethers,
  call,
  on,
  off,
  log = console.log,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) {
  const u = ethers.utils || ethers;
  const Interface = ethers.Interface || ethers.utils.Interface;
  const abiCoder = ethers.AbiCoder
    ? ethers.AbiCoder.defaultAbiCoder()
    : ethers.utils.defaultAbiCoder;
  const readFile = (file) => call('fileManager', 'readFile', file);
  const writeFile = (file, value) =>
    call(
      'fileManager',
      'writeFile',
      file,
      typeof value === 'string' ? value : JSON.stringify(value, null, 2)
    );
  const exists = (file) => call('fileManager', 'exists', file);
  const hashText = (text) => u.keccak256(u.toUtf8Bytes(text));
  const address = (value) => u.getAddress(value);
  let artifacts, fingerprint;
  const guard = async () => {
    invariant(
      await call('blockchain', 'isVM'),
      'Only Remix VM is supported. Wallets and external providers are refused.'
    );
    invariant(
      (await call('blockchain', 'getProvider')) === 'vm-osaka',
      'Select Remix VM (Osaka), not a fork, wallet, or external provider.'
    );
  };
  const rpc = async (method, params = []) => {
    await guard();
    return call('blockchain', 'sendRpc', method, params);
  };
  await guard();
  const accounts = (await rpc('eth_accounts')).map(address);
  invariant(accounts.length >= 5, 'At least five Remix VM accounts are required');
  const users = accounts.map((address) => ({ address }));
  const chainId = await rpc('eth_chainId');
  const ifaceOf = (artifact) => new Interface(artifact.abi);
  const attach = (name, at) => ({ name, address: address(at), iface: ifaceOf(artifacts[name]) });
  const block = () => rpc('eth_getBlockByNumber', ['latest', false]);
  const receipt = async (hash) => {
    for (let attempt = 0; attempt < 60; attempt++) {
      const result = await rpc('eth_getTransactionReceipt', [hash]);
      if (result) return result;
      await sleep(500);
    }
    throw new Error(`Receipt unavailable for ${hash}. Verify/resume; do not redeploy blindly.`);
  };

  /** Validate fresh compiler input, pinned dependency bytes and deployable artifacts. */
  async function compile() {
    artifacts = undefined;
    fingerprint = undefined;
    const config = JSON.parse(await readFile('remix.config.json'));
    invariant(
      config['solidity-compiler']?.settings?.evmVersion === 'osaka',
      'Expected the repository Osaka compiler profile'
    );
    invariant(
      typeof on === 'function' && typeof off === 'function',
      'Remix compiler event subscriptions are required'
    );
    // getCompilerState contains callbacks/Worker objects and cannot cross the
    // script iframe boundary. This API returns only serializable GUI fields;
    // validate the full effective settings using the compilation input below.
    checkVersion((await call('solidity', 'getCurrentCompilerConfig')).currentVersion);
    // A unique root proves the returned result belongs to this compilation,
    // rather than a previous compile whose artifacts happen to still be cached.
    const root = '.remix/Compile.sol';
    const source =
      '// SPDX-License-Identifier: GPL-3.0\npragma solidity ^0.8.34;\n' +
      '// Run ' +
      Date.now() +
      '-' +
      Math.random().toString(16).slice(2) +
      '\n' +
      [
        ...NAMES.map((name) => `import "../contracts/${name}.sol";`),
        'import "../contracts/NFT.sol";',
      ].join('\n');
    await writeFile(root, source);
    let result;
    const capture = (failed) => (target, compiledSource, language, data, input, version) => {
      if (target === root && compiledSource?.sources?.[root]?.content === source) {
        result = { source: compiledSource, data, input, version, failed };
      }
    };
    // Subscribe before compiling and keep input/output paired in the same event.
    // A cached getCompilationResult cannot prove which settings produced it.
    try {
      await on('solidity', 'compilationFinished', capture(false));
      await on('solidity', 'compilationFailed', capture(true));
      await call('solidity', 'compile', root);
      for (let attempt = 0; attempt < 180 && !result; attempt++) await sleep(500);
      invariant(
        result,
        'No fresh compilation event. Check Solidity Compiler errors and configuration.'
      );
      invariant(
        !result.failed && result.data?.contracts,
        'Compilation failed. Check Solidity Compiler errors and configuration.'
      );
      checkSettings(result.input, result.version, config);
      invariant(
        json(JSON.parse(result.input).sources) === json(result.source.sources),
        'Compiler input sources differ from compilation event sources'
      );
    } finally {
      await off('solidity', 'compilationFinished');
      await off('solidity', 'compilationFailed');
    }
    artifacts = {};
    const sourceHashes = {};
    for (const [file, entry] of Object.entries(result.source.sources)) {
      if (file === root) continue;
      // Validate resolved dependency bytes against the checked-in pinned cache.
      let local = file;
      const marker = file.indexOf('@openzeppelin/contracts');
      if (marker >= 0) {
        const tail = file.slice(marker).replace(/^@openzeppelin\/contracts(?:@[^/]+)?\//, '');
        local = '.deps/npm/@openzeppelin/contracts@5.6.1/' + tail;
      }
      const expected = await readFile(local);
      invariant(
        entry.content === expected,
        `Resolved source mismatch: ${file}. Use the pinned OpenZeppelin 5.6.1 cache.`
      );
      sourceHashes[file] = hashText(entry.content);
    }
    for (const name of [...NAMES, 'NFT']) {
      const candidates = Object.values(result.data.contracts).flatMap((file) =>
        file[name] ? [file[name]] : []
      );
      invariant(candidates.length === 1, `Expected exactly one ${name} artifact`);
      const artifact = candidates[0];
      invariant(
        JSON.parse(artifact.metadata).compiler.version === VERSION,
        'Unexpected artifact compiler'
      );
      checkArtifact(artifact);
      artifacts[name] = artifact;
      log(`${name}: runtime ${artifact.evm.deployedBytecode.object.length / 2}/24576 bytes`);
    }
    fingerprint = hashText(
      json({
        config: config['solidity-compiler'],
        sourceHashes,
        bytecode: Object.fromEntries(
          NAMES.map((name) => [name, artifacts[name].evm.bytecode.object])
        ),
      })
    );
    return { fingerprint, artifacts };
  }

  async function capabilities() {
    const before = BigInt((await block()).timestamp);
    const target = before + 7n * 86400n;
    let clock = false;
    try {
      await rpc('evm_setNextBlockTimestamp', [Number(target)]);
      await rpc('evm_mine', [{ blocks: 1 }]);
      clock = BigInt((await block()).timestamp) === target;
    } catch {
      /* Unsupported methods are a capability result, not a passing test. */
    }
    log(
      clock
        ? 'Verified timestamp control'
        : 'LIMITATION: VM time controls are unavailable/no-op. Long-duration tests and automatic handoff are blocked.'
    );
    return { clock, snapshots: false };
  }

  /**
   * Journaled sends persist pending intent, then hash, then confirmed receipt.
   * A saved hash can resume; an intent without a hash is ambiguous and must stop.
   * Omit record only for disposable fixtures; never auto-retry an unknown broadcast.
   */
  async function transact(tx, record, step) {
    await guard();
    invariant(BigInt(tx.gas || hex(GAS)) <= GAS, 'Transaction exceeds the production gas limit');
    tx = { ...tx, gas: tx.gas || hex(GAS), value: tx.value || '0x0' };
    if (record?.steps[step]) {
      const saved = record.steps[step];
      invariant(
        json(saved.tx) === json(tx),
        `Recorded transaction does not match requested step ${step}`
      );
      const actual = await receipt(saved.transactionHash);
      invariant(
        actual.blockHash === saved.blockHash && BigInt(actual.status) === 1n,
        'Recorded transaction missing or changed; possible VM reset'
      );
      return actual;
    }
    if (record?.pending) {
      invariant(record.pending.step === step, `Resume pending step ${record.pending.step} first`);
      invariant(
        json(record.pending.tx) === json(tx),
        'Pending transaction no longer matches the requested step'
      );
      invariant(
        record.pending.hash,
        'Ambiguous broadcast: no saved transaction hash. Inspect the VM or start a fresh deployment; automatic retry refused.'
      );
    } else if (record) {
      record.pending = {
        step,
        tx,
        nonce: await rpc('eth_getTransactionCount', [tx.from, 'latest']),
      };
      await writeFile(RECORD, record);
    }
    let hash = record?.pending?.hash;
    if (!hash) {
      hash = await rpc('eth_sendTransaction', [tx]);
      if (record) {
        record.pending.hash = hash;
        await writeFile(RECORD, record);
      }
    }
    const result = await receipt(hash);
    invariant(
      BigInt(result.status) === 1n,
      `Transaction failed: ${hash}. Pending record retained for inspection.`
    );
    invariant(BigInt(result.gasUsed) <= GAS, 'Receipt exceeds transaction gas limit');
    if (record) {
      record.steps[step] = {
        transactionHash: hash,
        blockHash: result.blockHash,
        contractAddress: result.contractAddress || null,
        tx,
      };
      record.pending = null;
      await writeFile(RECORD, record);
    }
    return result;
  }
  async function deploy(name, args = [], record, step = name) {
    const artifact = artifacts[name];
    const encoded = ifaceOf(artifact).encodeDeploy(args);
    checkArtifact(artifact, encoded);
    const result = await transact(
      { from: accounts[0], data: '0x' + artifact.evm.bytecode.object + encoded.slice(2) },
      record,
      step
    );
    const contract = attach(name, result.contractAddress);
    checkRuntime(artifact, await rpc('eth_getCode', [contract.address, 'latest']));
    return contract;
  }
  const send = (contract, user, method, args = [], value = 0n, record, step) =>
    transact(
      {
        from: user.address,
        to: contract.address,
        data: contract.iface.encodeFunctionData(method, args),
        value: hex(value),
      },
      record,
      step
    );
  const read = async (contract, method, args = [], caller = users[0]) =>
    normalize(
      contract.iface.decodeFunctionResult(
        method,
        await rpc('eth_call', [
          {
            from: caller.address,
            to: contract.address,
            data: contract.iface.encodeFunctionData(method, args),
          },
          'latest',
        ])
      )
    );
  const events = (contract, result, name) =>
    (result.logs || []).flatMap((entry) => {
      if (!equalAddress(entry.address, contract.address)) return [];
      try {
        const event = contract.iface.parseLog(entry);
        return event?.name === name ? [normalize(event.args)] : [];
      } catch {
        return [];
      }
    });
  const reverts = async (contract, user, method, args = [], value = 0n, errorName) => {
    // Remix eth_call returns revert bytes as a successful RPC response and drops
    // msg.value. Negative tests use transactions on disposable VM fixtures, with
    // both a failed receipt and the recorded REVERT (not out-of-gas) as proof.
    const tx = {
      from: user.address,
      to: contract.address,
      data: contract.iface.encodeFunctionData(method, args),
      value: hex(value),
      gas: hex(GAS),
    };
    let hash, mined, execution;
    try {
      hash = await rpc('eth_sendTransaction', [tx]);
      invariant(
        typeof hash === 'string' && /^0x[0-9a-f]{64}$/i.test(hash),
        'Missing transaction hash'
      );
      mined = await receipt(hash);
      execution = await rpc('eth_getExecutionResultFromSimulator', [hash]);
    } catch (error) {
      throw new Error(
        `${method}: RPC/transport failure is not proof of an EVM revert: ${error.message || error}`
      );
    }
    invariant(
      equalAddress(mined.transactionHash, hash),
      `${method}: receipt mismatch is not proof of an EVM revert`
    );
    invariant(BigInt(mined.status) === 0n, `${method} should revert`);
    invariant(BigInt(mined.gasUsed) <= GAS, 'Receipt exceeds transaction gas limit');
    invariant(
      execution?.exceptionError?.error === 'revert',
      `${method}: could not confirm an EVM revert (${execution?.exceptionError?.error || 'missing execution result'})`
    );
    if (errorName) {
      let actualError;
      try {
        actualError = contract.iface.parseError(execution.returnValue)?.name;
      } catch {
        /* Missing/malformed data cannot confirm a named error. */
      }
      invariant(
        actualError === errorName,
        `${method}: could not confirm expected ${errorName}; got ${actualError || 'undecodable revert data'}`
      );
    }
  };
  const h = {
    users,
    deploy,
    send,
    read,
    events,
    reverts,
    attach,
    rpc,
    block,
    encode: (types, values) => abiCoder.encode(types, values),
    id: u.id,
    ethBalance: async (user) => BigInt(await rpc('eth_getBalance', [user.address, 'latest'])),
  };

  async function bootstrap(record) {
    const coin = await deploy('DigilCoin', [accounts[0]], record);
    const token = await deploy('DigilToken', [accounts[0], coin.address, 18], record);
    const admin = users[0];
    await send(
      coin,
      admin,
      'grantRole',
      [u.id('MINTER_ROLE'), token.address],
      0n,
      record,
      'token-minter'
    );
    await send(coin, admin, 'setSpendWeight', [token.address, 10000], 0n, record, 'token-weight');
    const timelock = await deploy('DigilTimelock', [60, [], [], accounts[0]], record);
    const governor = await deploy(
      'DigilGovernor',
      [coin.address, timelock.address, token.address],
      record
    );
    for (const role of ['PROPOSER_ROLE', 'CANCELLER_ROLE', 'EXECUTOR_ROLE']) {
      await send(timelock, admin, 'grantRole', [u.id(role), governor.address], 0n, record, role);
    }
    const fixture = { coin, token, timelock, governor };
    await verifyFixture(fixture);
    return fixture;
  }

  async function verifyFixture({ coin, token, timelock, governor }) {
    for (const contract of [coin, token, timelock, governor])
      checkRuntime(
        artifacts[contract.name],
        await rpc('eth_getCode', [contract.address, 'latest'])
      );
    invariant(
      equalAddress((await read(token, 'owner'))[0], accounts[0]),
      'Token owner is not the bootstrap admin'
    );
    invariant(
      (await read(coin, 'hasRole', [u.id('MINTER_ROLE'), token.address]))[0],
      'Token minter role missing'
    );
    invariant(
      (await read(coin, 'spendWeightBps', [token.address]))[0] === 10000n,
      'Token spend weight is not 10000'
    );
    for (const role of ['PROPOSER_ROLE', 'CANCELLER_ROLE', 'EXECUTOR_ROLE']) {
      invariant(
        (await read(timelock, 'hasRole', [u.id(role), governor.address]))[0],
        `Governor ${role} missing`
      );
    }
    const zero = '0x' + '0'.repeat(40),
      adminRole = '0x' + '0'.repeat(64);
    invariant(
      !(await read(timelock, 'hasRole', [u.id('EXECUTOR_ROLE'), zero]))[0],
      'Open execution is not permitted by this deployment profile'
    );
    invariant(
      (await read(timelock, 'hasRole', [adminRole, timelock.address]))[0],
      'Timelock self administration missing'
    );
    invariant(
      (await read(timelock, 'hasRole', [adminRole, accounts[0]]))[0],
      'Bootstrap timelock admin missing'
    );
    invariant((await read(timelock, 'getMinDelay'))[0] === 60n, 'Unexpected timelock delay');
    invariant(
      equalAddress((await read(governor, 'token'))[0], coin.address),
      'Governor coin mismatch'
    );
    invariant(
      equalAddress((await read(governor, 'timelock'))[0], timelock.address),
      'Governor timelock mismatch'
    );
    invariant(
      (await read(coin, 'CLOCK_MODE'))[0] === (await read(governor, 'CLOCK_MODE'))[0],
      'Governor clock mismatch'
    );
    for (let id = 0; id < 21; id++)
      invariant(
        equalAddress((await read(token, 'ownerOf', [id]))[0], accounts[0]),
        `Unexpected planar custody for ${id}`
      );
    for (const role of [adminRole, u.id('MINTER_ROLE'), u.id('PAUSER_ROLE'), u.id('CONFIG_ROLE')]) {
      invariant(
        (await read(coin, 'hasRole', [role, accounts[0]]))[0],
        'Bootstrap coin role missing'
      );
    }
    await verifyRoleHolders(coin, {
      [adminRole]: [accounts[0]],
      [u.id('MINTER_ROLE')]: [accounts[0], token.address],
      [u.id('PAUSER_ROLE')]: [accounts[0]],
      [u.id('CONFIG_ROLE')]: [accounts[0]],
    });
    await verifyRoleHolders(timelock, {
      [adminRole]: [accounts[0], timelock.address],
      [u.id('PROPOSER_ROLE')]: [governor.address],
      [u.id('CANCELLER_ROLE')]: [governor.address],
      [u.id('EXECUTOR_ROLE')]: [governor.address],
    });
    log(
      'PASS bootstrap ownership, planar custody, minting, fee weight, clocks, timelock and Governor roles'
    );
  }

  /** Replay both role event types to reject unexpected holders, not just missing roles. */
  async function verifyRoleHolders(contract, expected) {
    const holders = {};
    // Remix requires an explicit topics array; an empty array retains all events.
    const logs = await rpc('eth_getLogs', [
      { address: contract.address, fromBlock: '0x0', toBlock: 'latest', topics: [] },
    ]);
    for (const entry of logs) {
      let parsed;
      try {
        parsed = contract.iface.parseLog(entry);
      } catch {
        continue;
      }
      if (!parsed || !['RoleGranted', 'RoleRevoked'].includes(parsed.name)) continue;
      const role = parsed.args[0].toLowerCase(),
        account = parsed.args[1].toLowerCase();
      holders[role] ||= new Set();
      if (parsed.name === 'RoleGranted') holders[role].add(account);
      else holders[role].delete(account);
    }
    for (const role of new Set([...Object.keys(expected), ...Object.keys(holders)])) {
      const wanted = (expected[role] || []).map((value) => value.toLowerCase()).sort();
      invariant(
        json([...(holders[role] || [])].sort()) === json(wanted),
        `Unexpected role holders on ${contract.name}: ${role}`
      );
    }
  }

  async function loadRecord() {
    invariant(await exists(RECORD), 'No deployment record. Run deploy.js first.');
    const record = JSON.parse(await readFile(RECORD));
    invariant(
      record.schema === 1 &&
        record.chainId === chainId &&
        equalAddress(record.admin, accounts[0]) &&
        record.fingerprint === fingerprint,
      'Deployment record does not match this chain, admin, or current build. Use a separate workspace for a fresh deployment.'
    );
    for (const step of Object.values(record.steps)) {
      const actual = await receipt(step.transactionHash);
      invariant(
        actual.blockHash === step.blockHash && BigInt(actual.status) === 1n,
        'Deployment history mismatch; possible VM reset'
      );
      invariant(
        equalAddress(actual.contractAddress, step.contractAddress),
        'Deployment address changed'
      );
      const transaction = await rpc('eth_getTransactionByHash', [step.transactionHash]);
      invariant(
        transaction &&
          equalAddress(transaction.from, step.tx.from) &&
          equalAddress(transaction.to, step.tx.to || null) &&
          (transaction.input || transaction.data).toLowerCase() === step.tx.data.toLowerCase() &&
          BigInt(transaction.value) === BigInt(step.tx.value),
        'Recorded constructor/call input does not match the chain'
      );
    }
    return record;
  }
  async function deployRecorded() {
    let record;
    if (await exists(RECORD)) record = await loadRecord();
    else {
      record = {
        schema: 1,
        chainId,
        admin: accounts[0],
        fingerprint,
        runId: Date.now().toString(),
        profile: 'bootstrap',
        steps: {},
        pending: null,
      };
      await writeFile(RECORD, record);
    }
    const fixture = await bootstrap(record);
    record.addresses = Object.fromEntries(
      Object.entries(fixture).map(([name, contract]) => [name, contract.address])
    );
    record.complete = true;
    await writeFile(RECORD, record);
    log(JSON.stringify(record.addresses, null, 2));
    return fixture;
  }
  async function verifyRecorded(pendingPrefix) {
    const record = await loadRecord();
    invariant(
      record.complete &&
        (!record.pending || (pendingPrefix && record.pending.step.startsWith(pendingPrefix))),
      'Deployment has an incomplete operation. Resume its recorded deploy.js or seed-demo.js step.'
    );
    for (const [key, at] of Object.entries(record.addresses)) {
      const name = 'Digil' + key[0].toUpperCase() + key.slice(1);
      invariant(
        equalAddress(at, record.steps[name]?.contractAddress),
        `Address record mismatch: ${key}`
      );
    }
    const fixture = Object.fromEntries(
      Object.entries(record.addresses).map(([key, at]) => [
        key,
        attach('Digil' + key[0].toUpperCase() + key.slice(1), at),
      ])
    );
    const args = {
      DigilCoin: [accounts[0]],
      DigilToken: [accounts[0], fixture.coin.address, 18],
      DigilTimelock: [60, [], [], accounts[0]],
      DigilGovernor: [fixture.coin.address, fixture.timelock.address, fixture.token.address],
    };
    for (const name of NAMES) {
      const expected =
        '0x' +
        artifacts[name].evm.bytecode.object +
        ifaceOf(artifacts[name]).encodeDeploy(args[name]).slice(2);
      invariant(
        record.steps[name].tx.data === expected,
        `Constructor arguments do not match the deployment profile: ${name}`
      );
    }
    await verifyFixture(fixture);
    return fixture;
  }
  return {
    compile,
    capabilities,
    h,
    bootstrap,
    deployRecorded,
    verifyRecorded,
    verifyFixture,
    loadRecord,
    readFile,
    writeFile,
    log,
  };
}

module.exports = {
  createRuntime,
  invariant,
  canonical,
  checkSettings,
  checkArtifact,
  checkRuntime,
  normalize,
  NAMES,
  GAS,
  VERSION,
};
