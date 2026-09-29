(async () => {
  const only = []; // Empty runs all smoke cases; otherwise list exact scenario IDs.
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(module);
  await module.exports.run('test', { ethers: require('ethers'), remix, only });
})().catch(error => { console.error('FAIL smoke suite:', error.message || error); throw error; });
