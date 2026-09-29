// Remix Run Script: verify the recorded deployment against fresh artifacts/history.
// Does not repair role drift or send deployment transactions; failures need inspection.
(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(
    module
  );
  await module.exports.run('verify', { ethers: require('ethers'), remix });
})().catch((error) => {
  console.error('FAIL verification:', error.message || error);
  throw error;
});
