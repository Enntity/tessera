// SPDX-License-Identifier: MIT
// Filesystem traversal, hashing and redaction cannot block ownership timers.
// Use the same adapters as explicit reads; only index metadata crosses threads.
import { parentPort } from 'node:worker_threads';
import { adapters } from './memory-panorama.mjs';
parentPort.on('message',({source,root})=>{
  try{parentPort.postMessage({entries:adapters[source](root)});}
  catch(error){parentPort.postMessage({error:{code:error.code??'SCAN_FAILED'}});}
});
