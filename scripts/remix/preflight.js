// Remix Run Script: validate the compiler, source bytes, sizes and VM capabilities.
// Deploys no contracts. Run before test.js or deploy.js after source/config changes.
(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(
    module
  );
  await module.exports.run('preflight', { ethers: require('ethers'), remix });
})().catch((error) => {
  console.error('FAIL preflight:', error.message || error);
  throw error;
});
