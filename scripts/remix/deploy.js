// Remix Run Script: deploy/resume the four-contract bootstrap and verify its roles.
// Retains admin control; recovery uses .remix/deployment.json in this same VM.
(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(
    module
  );
  await module.exports.run('deploy', { ethers: require('ethers'), remix });
})().catch((error) => {
  console.error('FAIL deployment:', error.message || error);
  throw error;
});
