// One benign request through the existing configured provider. Never retry.
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
const [binary, directory] = process.argv.slice(2);
if(!binary || !directory) throw new Error('Supply binary and exact probe directory');
await fs.mkdir(directory,{recursive:true});
const args=['--print','Reply with exactly CCP_CLIENT_OK. Do not use tools.',
  '--output-format','json','--max-turns','1','--no-session-persistence',
  '--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}',
  '--settings','{"disableAllHooks":true}','--setting-sources','user'];
const result=await new Promise((resolve,reject)=>{
  const child=spawn(binary,args,{cwd:directory,windowsHide:true,
    env:{...process.env,TEMP:directory,TMP:directory,DISABLE_AUTOUPDATER:'1'},stdio:['ignore','pipe','pipe']});
  let stdout='',stderr='';
  child.stdout.on('data',b=>stdout+=b);
  child.stderr.on('data',b=>stderr+=b);
  child.on('error',reject);
  child.on('close',(code,signal)=>resolve({code,signal,stdout,stderr}));
});
await fs.writeFile(path.join(directory,'probe-stdout.json'),result.stdout);
await fs.writeFile(path.join(directory,'probe-stderr.log'),result.stderr);
let output;try{output=JSON.parse(result.stdout);}catch{}
if(Array.isArray(output))output=output.filter(x=>x.type==='result').at(-1);
const receipt={exitCode:result.code,signal:result.signal,childExited:true,
  passed:result.code===0 && output?.is_error!==true && output?.result?.trim()==='CCP_CLIENT_OK',
  response:output?.result,subtype:output?.subtype,usage:output?.usage,
  modelUsage:output?.modelUsage,requestRetries:0};
await fs.writeFile(path.join(directory,'probe-receipt.json'),JSON.stringify(receipt,null,2));
console.log(JSON.stringify(receipt,null,2));
if(!receipt.passed)process.exitCode=1;
