// SPDX-License-Identifier: MIT
// Share only observations that are currently in flight. Completed results are
// never cached here; a later ownership observation starts a fresh request.
export function singleFlight(fn){
  let flight;
  return ()=>{
    if(!flight)flight=Promise.resolve().then(()=>fn()).finally(()=>{flight=undefined;});
    return flight;
  };
}
