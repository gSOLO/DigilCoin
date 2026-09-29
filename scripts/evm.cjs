/**
 * Shared Node-only EthereumJS harness with deterministic disposable accounts.
 * Owns transaction execution, simulated time, deployments and ABI exercise data.
 * Never connect these public test keys to funded accounts or external networks.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ethers = require('ethers');
const { createVM, runTx } = require('@ethereumjs/vm');
const { Common, Mainnet, Hardfork } = require('@ethereumjs/common');
const { createLegacyTx } = require('@ethereumjs/tx');
const { createBlock } = require('@ethereumjs/block');
const {
  createAccount,
  createAddressFromPrivateKey,
  createAddressFromString,
  hexToBytes,
  bytesToHex,
} = require('@ethereumjs/util');

const unit = 10n ** 18n;
const floor = 100000000000000n;
const gasLimit = 16777216n;

/** Create an isolated VM; diagnostic size exemptions are never deployment approval. */
async function createHarness(contracts, diagnostic = false) {
  const common = new Common({ chain: Mainnet, hardfork: Hardfork.Osaka });
  const vm = await createVM({
    common,
    evmOpts: {
      allowUnlimitedContractSize: diagnostic,
      allowUnlimitedInitCodeSize: diagnostic,
    },
  });
  const h = {
    vm,
    common,
    contracts,
    time: 1800000000n,
    height: 1n,
    users: [],
    libraries: new Map(),
  };
  const deployed = new Map(),
    exercised = new Map();
  vm.evm.events.on('beforeMessage', (message) => {
    const contract = message.to && deployed.get(message.to.toString().toLowerCase());
    if (!contract || !h.scenario || message.data.length < 4) return;
    try {
      const method = contract.iface.getFunction(bytesToHex(message.data.slice(0, 4)));
      if (!method) return;
      const key = `${contract.name}.${method.format('sighash')}`;
      if (!exercised.has(key)) exercised.set(key, new Set());
      exercised.get(key).add(h.scenario);
    } catch {}
  });
  h.writeCoverage = () => {
    if (!process.env.DIGIL_COVERAGE_RUN) return;
    const directory = path.join(__dirname, '../.remix/coverage');
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(
      path.join(directory, path.basename(process.argv[1]) + '.json'),
      JSON.stringify(
        {
          run: process.env.DIGIL_COVERAGE_RUN,
          calls: Object.fromEntries([...exercised].map(([key, names]) => [key, [...names].sort()])),
        },
        null,
        2
      )
    );
  };
  for (let i = 1; i <= 60; i++) {
    const key = hexToBytes('0x' + i.toString(16).padStart(64, '0'));
    const addr = createAddressFromPrivateKey(key);
    await vm.stateManager.putAccount(addr, createAccount({ balance: 10000n * unit }));
    h.users.push({ key, addr, address: addr.toString() });
  }
  h.block = () =>
    createBlock(
      {
        header: {
          number: h.height,
          timestamp: h.time,
          gasLimit: 60000000n,
          baseFeePerGas: 1n,
        },
      },
      { common }
    );
  h.tx = async (user, to, data, value = 0n, tolerate = false) => {
    h.time++;
    h.height++;
    const account = await vm.stateManager.getAccount(user.addr);
    const tx = createLegacyTx(
      {
        nonce: account.nonce,
        gasLimit,
        gasPrice: 2n,
        to: to ? createAddressFromString(to) : undefined,
        data: hexToBytes(data),
        value,
      },
      { common }
    ).sign(user.key);
    const result = await runTx(vm, { tx, block: h.block() });
    if (!tolerate)
      assert.ok(
        !result.execResult.exceptionError,
        `Transaction ${data.slice(0, 10)} reverted: ${result.execResult.exceptionError?.error} ${bytesToHex(result.execResult.returnValue)}`
      );
    return result;
  };
  h.deploy = async (name, args = [], testOnly = false, file = `contracts/${name}.sol`) => {
    const artifact = contracts[file][name];
    // Solidity library ABIs can spell contract return types by interface name.
    const normalize = (parameter) =>
      parameter.internalType?.startsWith('contract ')
        ? { ...parameter, type: 'address' }
        : parameter;
    const iface = new ethers.Interface(
      artifact.abi.map((entry) => ({
        ...entry,
        ...(entry.inputs && { inputs: entry.inputs.map(normalize) }),
        ...(entry.outputs && { outputs: entry.outputs.map(normalize) }),
      }))
    );
    let bytecode = artifact.evm.bytecode.object;
    for (const [libraryFile, libraries] of Object.entries(
      artifact.evm.bytecode.linkReferences || {}
    )) {
      for (const [library, locations] of Object.entries(libraries)) {
        const key = `${libraryFile}:${library}`;
        if (!h.libraries.has(key))
          h.libraries.set(key, (await h.deploy(library, [], testOnly, libraryFile)).address);
        const address = h.libraries.get(key).slice(2);
        for (const location of locations) {
          bytecode =
            bytecode.slice(0, location.start * 2) +
            address +
            bytecode.slice((location.start + location.length) * 2);
        }
      }
    }
    // These existing Node-only harnesses are not deployment acceptance evidence.
    // Production contracts, new actors, and every other test keep normal limits.
    const legacyHarness =
      testOnly &&
      ['AlphaTestSuite', 'BetaTestSuite', 'FoxtrotTestSuite', 'GammaTestSuite'].includes(name) &&
      file.startsWith('tests/');
    vm.evm.allowUnlimitedContractSize = diagnostic || legacyHarness;
    vm.evm.allowUnlimitedInitCodeSize = diagnostic || legacyHarness;
    try {
      const result = await h.tx(
        h.users[0],
        null,
        '0x' + bytecode + iface.encodeDeploy(args).slice(2)
      );
      const contract = { address: result.createdAddress.toString(), iface, name };
      if (['DigilCoin', 'DigilToken', 'DigilGovernor', 'DigilTimelock'].includes(name))
        deployed.set(contract.address.toLowerCase(), contract);
      return contract;
    } finally {
      vm.evm.allowUnlimitedContractSize = diagnostic;
      vm.evm.allowUnlimitedInitCodeSize = diagnostic;
    }
  };
  h.send = (contract, user, method, args = [], value = 0n, tolerate = false) =>
    h.tx(user, contract.address, contract.iface.encodeFunctionData(method, args), value, tolerate);
  h.read = async (contract, method, args = [], caller = h.users[0]) => {
    await vm.stateManager.checkpoint();
    try {
      const result = await vm.evm.runCall({
        to: createAddressFromString(contract.address),
        caller: caller.addr,
        data: hexToBytes(contract.iface.encodeFunctionData(method, args)),
        gasLimit,
        block: h.block(),
        isStatic: true,
      });
      assert.ok(
        !result.execResult.exceptionError,
        `Read ${method} reverted: ${bytesToHex(result.execResult.returnValue)}`
      );
      return contract.iface.decodeFunctionResult(method, bytesToHex(result.execResult.returnValue));
    } finally {
      await vm.stateManager.revert();
    }
  };
  h.events = (contract, result, name) =>
    (result.execResult.logs || []).flatMap((log) => {
      if (bytesToHex(log[0]).toLowerCase() !== contract.address.toLowerCase()) return [];
      try {
        const event = contract.iface.parseLog({
          topics: log[1].map(bytesToHex),
          data: bytesToHex(log[2]),
        });
        return event?.name === name ? [event.args] : [];
      } catch {
        return [];
      }
    });
  h.result = (contract, method, result) =>
    contract.iface.decodeFunctionResult(method, bytesToHex(result.execResult.returnValue));
  h.reverts = async (contract, user, method, args = [], value = 0n, error) => {
    const result = await h.send(contract, user, method, args, value, true);
    assert.ok(result.execResult.exceptionError, `${method} should revert`);
    if (error)
      assert.equal(
        contract.iface.parseError(bytesToHex(result.execResult.returnValue))?.name,
        error
      );
  };
  return h;
}

/** Deploy Coin/Token and wire Token minting permission plus eligible fee weight. */
async function bootstrap(h) {
  const admin = h.users[0];
  const coin = await h.deploy('DigilCoin', [admin.address]);
  const token = await h.deploy('DigilToken', [admin.address, coin.address, 18]);
  await h.send(coin, admin, 'grantRole', [ethers.id('MINTER_ROLE'), token.address]);
  await h.send(coin, admin, 'setSpendWeight', [token.address, 10000]);
  return { coin, token };
}

module.exports = {
  createHarness,
  bootstrap,
  unit,
  floor,
  gasLimit,
  ethers,
  bytesToHex,
  hexToBytes,
  createAddressFromString,
  createAccount,
};
