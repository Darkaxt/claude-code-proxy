// Local stdio adapter for the existing opt-in proxy Images API. No dependencies.
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import readline from 'node:readline';
import {pathToFileURL} from 'node:url';

export const VERSION='1.0.0';
const MAX_FILE=20*1024*1024, MAX_INPUT=50*1024*1024, MAX_RESPONSE=128*1024*1024;
const common={
 prompt:{type:'string',description:'The complete image-generation/edit instruction, already disclosed to the user.'},
 output_directory:{type:'string',description:'Absolute directory for new image files; existing files are never replaced.'},
 size:{type:'string',description:'Image size supported by the proxy; defaults to auto.'},
 quality:{type:'string',enum:['auto','low','medium','high']},
 background:{type:'string',enum:['auto','opaque','transparent']},
};
export const tools=[
 {name:'generate_image',description:'Generate one image with the configured proxy and save a new file. Returns its absolute path and hash. No automatic retries.',inputSchema:{type:'object',properties:common,required:['prompt'],additionalProperties:false},annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:false,openWorldHint:true}},
 {name:'edit_image',description:'Edit one image using one to five local reference images. Saves a new file and returns its path/hash; originals are preserved. No automatic retries.',inputSchema:{type:'object',properties:{...common,images:{type:'array',items:{type:'string'},minItems:1,maxItems:5,description:'Absolute paths to the necessary reference images only.'}},required:['prompt','images'],additionalProperties:false},annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:false,openWorldHint:true}},
];

function format(bytes){
 if(bytes.length>=24&&bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))return {mime:'image/png',extension:'png',width:bytes.readUInt32BE(16),height:bytes.readUInt32BE(20)};
 if(bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255)return {mime:'image/jpeg',extension:'jpg'};
 if(bytes.length>=12&&bytes.toString('ascii',0,4)==='RIFF'&&bytes.toString('ascii',8,12)==='WEBP')return {mime:'image/webp',extension:'webp'};
 if(bytes.length>=10&&['GIF87a','GIF89a'].includes(bytes.toString('ascii',0,6)))return {mime:'image/gif',extension:'gif'};
 throw Error('Image is not a recognized PNG, JPEG, WebP or GIF file');
}
function endpoint(value){
 const url=new URL(value);
 if(url.protocol!=='http:'||!['127.0.0.1','[::1]'].includes(url.hostname)||url.username||url.password||url.search||url.hash||url.pathname!=='/')throw Error('Proxy must be a plain loopback HTTP origin');
 return url;
}
async function post(url,operation,body){
 const encoded=Buffer.from(JSON.stringify(body));
 if(encoded.length>64*1024*1024)throw Error('Image request exceeds proxy request limit');
 return new Promise((resolve,reject)=>{
  const request=http.request(new URL(`/v1/images/${operation}`,url),{method:'POST',agent:false,headers:{'content-type':'application/json','content-length':encoded.length}},response=>{
   const chunks=[];let length=0;
   response.on('data',chunk=>{length+=chunk.length;if(length>MAX_RESPONSE){response.destroy(Error('Image response exceeds proxy limit'));return;}chunks.push(chunk);});
   response.on('error',reject);
   response.on('end',()=>{
    let output;try{output=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return reject(Error(`Proxy returned non-JSON data (HTTP ${response.statusCode})`));}
    if(response.statusCode<200||response.statusCode>=300){
     const error=output.error??{};
     return reject(Object.assign(Error(String(error.message??`Image request failed (HTTP ${response.statusCode})`)),{status:response.statusCode,code:error.code,type:error.type}));
    }
    resolve(output);
   });
  });
  request.on('error',reject);request.end(encoded);
 });
}

export async function callTool(name,args,{baseUrl='http://127.0.0.1:8317',outputRoot='D:/Tools/claudegpt-imagegen/images'}={}){
 try{
  const tool=tools.find(t=>t.name===name);
  if(!tool)throw Error('Unknown image tool');
  if(!args||typeof args!=='object'||Array.isArray(args))throw Error('Tool arguments must be an object');
  for(const key of Object.keys(args))if(!(key in tool.inputSchema.properties))throw Error(`Unknown argument: ${key}`);
  if(typeof args.prompt!=='string'||!args.prompt.trim()||Buffer.byteLength(args.prompt)>65536)throw Error('Prompt must contain 1–65536 UTF-8 bytes');
  const destination=args.output_directory??outputRoot;
  if(typeof destination!=='string'||!path.isAbsolute(destination))throw Error('Output directory must be absolute');
  const url=endpoint(baseUrl);
  const body={model:'gpt-image-2',prompt:args.prompt,n:1};
  for(const key of ['size','quality','background']){
   const value=args[key]??'auto';
   if(typeof value!=='string'||!value)throw Error(`Invalid ${key}`);
   if(common[key].enum&&!common[key].enum.includes(value))throw Error(`Unsupported ${key}`);
   body[key]=value;
  }
  if(name==='edit_image'){
   if(!Array.isArray(args.images)||args.images.length<1||args.images.length>5)throw Error('Supply one to five local reference images');
   body.images=[];let total=0;
   for(const file of args.images){
    if(typeof file!=='string'||!path.isAbsolute(file))throw Error('Reference image paths must be absolute');
    const handle=await fs.open(file,'r');let bytes;
    try{
     const stat=await handle.stat();
     if(!stat.isFile()||stat.size>MAX_FILE)throw Error('Reference image must be a regular file of at most 20 MiB');
     total+=stat.size;if(total>MAX_INPUT)throw Error('Reference images exceed 50 MiB in total');
     bytes=await handle.readFile();
    }finally{await handle.close();}
    const info=format(bytes);
    body.images.push({image_url:`data:${info.mime};base64,${bytes.toString('base64')}`});
   }
  }
  const output=await post(url,name==='edit_image'?'edits':'generations',body);
  if(!Array.isArray(output.data)||output.data.length!==1||typeof output.data[0].b64_json!=='string')throw Error('Proxy did not return exactly one image');
  const encoded=output.data[0].b64_json;
  if(!encoded.length||encoded.length%4!==0||!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded))throw Error('Proxy returned malformed image base64');
  const bytes=Buffer.from(encoded,'base64');
  const info=format(bytes);
  await fs.mkdir(destination,{recursive:true});
  const file=path.join(destination,`image-${crypto.randomUUID()}.${info.extension}`);
  await fs.writeFile(file,bytes,{flag:'wx'});
  const result={path:file,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),mime:info.mime,...(info.width?{width:info.width,height:info.height}:{})};
  return {content:[{type:'text',text:JSON.stringify(result)}],isError:false};
 }catch(error){
  // Return the actual failure to the caller; never replay or substitute a provider.
  return {content:[{type:'text',text:JSON.stringify({error:error.message,...(error.status?{httpStatus:error.status}:{}),...(error.code?{code:error.code}:{}),...(error.type?{type:error.type}:{})})}],isError:true};
 }
}

async function serve(){
 const flags=process.argv.slice(2);let baseUrl='http://127.0.0.1:8317',outputRoot='D:/Tools/claudegpt-imagegen/images';
 for(let i=0;i<flags.length;i+=2){
  if(!flags[i+1])throw Error('Missing option value');
  if(flags[i]==='--base-url')baseUrl=flags[i+1];
  else if(flags[i]==='--output-root')outputRoot=flags[i+1];
  else throw Error('Unknown option');
 }
 endpoint(baseUrl);
 if(!path.isAbsolute(outputRoot))throw Error('Output root must be absolute');
 const input=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
 for await(const line of input){
  if(!line.trim())continue;
  let request,response;
  try{
   if(Buffer.byteLength(line)>1024*1024)throw Error('MCP request too large');
   request=JSON.parse(line);
   if(request.jsonrpc!=='2.0'||typeof request.method!=='string')throw Error('Invalid JSON-RPC request');
   if(!Object.hasOwn(request,'id'))continue;
   if(request.method==='initialize'){
    const supported=['2024-11-05','2025-03-26'];
    const proposed=request.params?.protocolVersion;
    response={protocolVersion:supported.includes(proposed)?proposed:'2025-03-26',capabilities:{tools:{listChanged:false}},serverInfo:{name:'claudegpt-imagegen',version:VERSION}};
   }else if(request.method==='ping')response={};
   else if(request.method==='tools/list')response={tools};
   else if(request.method==='tools/call')response=await callTool(request.params?.name,request.params?.arguments,{baseUrl,outputRoot});
   else{process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,error:{code:-32601,message:'Method not found'}})+'\n');continue;}
   process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result:response})+'\n');
  }catch(error){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request?.id??null,error:{code:-32600,message:error.message}})+'\n');}
 }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href){
 serve().catch(()=>{process.stderr.write('ImageGen MCP server failed to start. Check its loopback origin and installation.\n');process.exitCode=1;});
}
