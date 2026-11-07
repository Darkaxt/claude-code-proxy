import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {callTool} from './imagegen-mcp.mjs';

const root=process.env.IMAGEGEN_TEST_ROOT;
assert.ok(root&&path.isAbsolute(root),'Supply an exact task-owned IMAGEGEN_TEST_ROOT');
const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

test('stdio discovery, generation, edit and visible nonretryable errors preserve file/protocol boundaries',async()=>{
 await fs.mkdir(root,{recursive:true});
 const directory=await fs.mkdtemp(path.join(root,'mcp-fixture-'));
 const requests=[];
 const server=http.createServer(async(req,res)=>{
  const chunks=[];for await(const chunk of req)chunks.push(chunk);
  const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));requests.push({url:req.url,body});
  res.setHeader('content-type','application/json');
  if(body.prompt==='fictional policy fixture'){res.writeHead(403);res.end(JSON.stringify({error:{message:'Fictional fixture policy interruption',code:'cyber_policy',type:'permission_error'}}));}
  else res.end(JSON.stringify({created:1,data:[{b64_json:png}]}));
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const origin=`http://127.0.0.1:${server.address().port}`;
 const child=spawn(process.execPath,[fileURLToPath(new URL('./imagegen-mcp.mjs',import.meta.url)),'--base-url',origin,'--output-root',directory],{stdio:['pipe','pipe','pipe'],windowsHide:true});
 const exited=new Promise(resolve=>child.once('close',code=>resolve(code)));
 let buffer='',stderr='';let next=1;
 const pending=new Map();
 child.stderr.on('data',chunk=>stderr+=chunk);
 child.stdout.on('data',chunk=>{
  buffer+=chunk;
  let end;while((end=buffer.indexOf('\n'))>=0){
   const message=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
   const resolve=pending.get(message.id);assert.ok(resolve,'Unexpected stdout message');pending.delete(message.id);resolve(message);
  }
 });
 function rpc(method,params){const id=next++;return new Promise(resolve=>{pending.set(id,resolve);child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});}
 try{
  const init=await rpc('initialize',{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'fixture',version:'1'}});
  assert.equal(init.result.protocolVersion,'2025-03-26');assert.ok(init.result.capabilities.tools);
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
  const listed=await rpc('tools/list',{});assert.deepEqual(listed.result.tools.map(t=>t.name),['generate_image','edit_image']);
  const generated=await rpc('tools/call',{name:'generate_image',arguments:{prompt:'fictional generation fixture'}});
  assert.equal(generated.result.isError,false);
  const first=JSON.parse(generated.result.content[0].text);
  assert.equal(await fs.readFile(first.path,'base64'),png);assert.equal(first.width,1);assert.equal(first.height,1);
  assert.equal(first.mime,'image/png');assert.ok(!generated.result.content[0].text.includes(png));
  const edited=await rpc('tools/call',{name:'edit_image',arguments:{prompt:'fictional edit fixture',images:[first.path],background:'transparent'}});
  assert.equal(edited.result.isError,false);
  const second=JSON.parse(edited.result.content[0].text);assert.notEqual(second.path,first.path);
  assert.equal(await fs.readFile(first.path,'base64'),png);
  assert.equal(requests[0].url,'/v1/images/generations');assert.equal(requests[0].body.model,'gpt-image-2');assert.equal(requests[0].body.n,1);
  assert.equal(requests[1].url,'/v1/images/edits');assert.equal(requests[1].body.images[0].image_url,`data:image/png;base64,${png}`);
  assert.equal(requests[1].body.background,'transparent');
  const failed=await rpc('tools/call',{name:'generate_image',arguments:{prompt:'fictional policy fixture'}});
  assert.equal(failed.result.isError,true);assert.match(failed.result.content[0].text,/cyber_policy/);assert.match(failed.result.content[0].text,/403/);
  assert.equal(requests.length,3,'Fictional refusal must be returned without a retry');
  assert.equal((await rpc('not-a-method',{})).error.code,-32601);
  child.stdin.end();assert.equal(await exited,0);assert.equal(stderr,'');
  const invalid=await callTool('generate_image',{prompt:'not sent',model:'another-model'},{baseUrl:origin,outputRoot:directory});
  assert.equal(invalid.isError,true);assert.equal(requests.length,3);
  const remote=await callTool('generate_image',{prompt:'not sent'},{baseUrl:'http://example.invalid',outputRoot:directory});
  assert.equal(remote.isError,true);assert.equal(requests.length,3);
  const large=path.join(directory,'large.png');const handle=await fs.open(large,'wx');await handle.truncate(20*1024*1024+1);await handle.close();
  assert.equal((await callTool('edit_image',{prompt:'not sent',images:[large]},{baseUrl:origin,outputRoot:directory})).isError,true);
  assert.equal(requests.length,3);
 }finally{
  if(child.exitCode===null){child.stdin.end();await exited;}
  await new Promise(resolve=>server.close(resolve));
 }
});
