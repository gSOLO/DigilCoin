(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(module);
  await module.exports.run('verify', { ethers: require('ethers'), remix });
})().catch(error => { console.error('FAIL verification:', error.message || error); throw error; });
