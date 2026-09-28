const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { root, compile, sourcesIn, checkSizes } = require('./compile.cjs');
const { createHarness, bootstrap, gasLimit, ethers, unit, bytesToHex, hexToBytes, createAddressFromString, createAccount } = require('./evm.cjs');

async function main() {
  const sources = { ...sourcesIn('contracts'), ...sourcesIn('tests', file => file.endsWith('_test.sol')) };
  const contracts = compile(sources);
  const diagnostic = process.argv.includes('--diagnostic');
  if (diagnostic) console.warn('DIAGNOSTIC ONLY: production code-size exemptions enabled; not deployment validation.');
  else checkSizes(contracts);
  const h = await createHarness(contracts, diagnostic);
  const { coin, token } = await bootstrap(h);
  // Replace fixture addresses in memory, never in the checked-in Remix helper.
  const helper = sources['contracts/DigilTestLibrary.sol'].content
    .replace('0xd9145CCE52D386f254917e481eB44e9943F39138', ethers.getAddress(coin.address))
    .replace('0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8', ethers.getAddress(token.address));
  contracts['contracts/DigilTestLibrary.sol'] = compile({ 'contracts/DigilTestLibrary.sol': { content: helper } })['contracts/DigilTestLibrary.sol'];
  const accountSource = fs.readFileSync(path.join(root, 'tests/remix_accounts.sol'), 'utf8');
  const accounts = [...accountSource.matchAll(/accounts\[\d+\]\s*=\s*(0x[0-9a-fA-F]{40})/g)].map(match => createAddressFromString(match[1]));
  for (const address of accounts) await h.vm.stateManager.putAccount(address, createAccount({ balance: 10000n * unit }));
  const assertArtifact = contracts['remix_tests.sol']?.Assert || contracts['tests/remix_tests.sol'].Assert;
  const assertInterface = new ethers.Interface(assertArtifact.abi);
  let passed = 0, failed = 0;
  for (const [file, source] of Object.entries(sources).filter(([file]) => file.endsWith('_test.sol'))) {
    const name = Object.keys(contracts[file])[0];
    const suite = await h.deploy(name, [], true, file);
    for (const match of source.content.matchAll(/function\s+(beforeAll|test\w+)\s*\(/g)) {
      const method = match[1];
      const preceding = source.content.slice(0, match.index).split('\n');
      const comments = [];
      for (let i = preceding.length - 1; i >= 0; i--) {
        const line = preceding[i].trim();
        if (!line || line.startsWith('//')) comments.unshift(line); else break;
      }
      const annotation = comments.join('\n');
      const caller = accounts[Number(annotation.match(/#sender:\s*account-(\d+)/)?.[1] || 0)];
      const value = BigInt(annotation.match(/#value:\s*(\d+)/)?.[1] || 0);
      const data = hexToBytes(suite.iface.encodeFunctionData(method));
      // Remix senders have no available signing keys. Execute equivalent calls with
      // transaction intrinsic gas deducted, while resetting warm storage between calls.
      const intrinsic = 21000n + data.reduce((total, byte) => total + (byte === 0 ? 4n : 16n), 0n);
      h.time++; h.height++;
      await h.vm.evm.journal.cleanup();
      h.vm.stateManager.originalStorageCache.clear();
      const result = await h.vm.evm.runCall({ to: createAddressFromString(suite.address), caller, origin: caller,
        data, value, gasLimit: gasLimit - intrinsic, block: h.block(),
      });
      const errors = [];
      if (result.execResult.exceptionError) errors.push(`${result.execResult.exceptionError.error}: ${bytesToHex(result.execResult.returnValue)}`);
      for (const log of result.execResult.logs || []) {
        try {
          const event = assertInterface.parseLog({ topics: log[1].map(bytesToHex), data: bytesToHex(log[2]) });
          if (event?.args.passed === false) errors.push(event.args.message || event.name);
        } catch { }
      }
      if (errors.length) {
        failed++;
        console.error(`FAIL ${name}.${method}: ${errors.join('; ')}`);
      } else if (method !== 'beforeAll') {
        passed++;
        console.log(`PASS ${name}.${method} gas=${result.execResult.executionGasUsed + intrinsic}`);
      }
    }
  }
  console.log(`Remix suites: ${passed} passed; ${failed} failed; per-call gas limit ${gasLimit}`);
  assert.equal(failed, 0);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
