#if VETA_JIT_DEVELOPMENT
enum PS2WebClient {
    static let page = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <style>html,body{margin:0;width:100%;height:100%;background:#000;color:white;font:17px system-ui;overflow:hidden}canvas{width:100%;height:100%;object-fit:contain;display:block}#start{position:absolute;left:25%;top:40%;width:50%;min-height:52px;border:0;border-radius:12px;background:#a5eed7;color:#102820;font:700 20px system-ui}#status{position:absolute;top:42%;width:100%;text-align:center;pointer-events:none}</style></head>
    <body><canvas id="outputCanvas" width="640" height="480" tabindex="0"></canvas><button id="start" hidden></button><div id="status"></div>
    <script type="module">

    // Private QA candidate: per-instance bounded cache, no background prefetch.
    function createDiscRangeCache({size,fetchRange,blockSize=65536,maxBytes=4194304,maxInFlight=4,maxReadBytes=1048576}) {
      for(const [name,value] of Object.entries({size,blockSize,maxBytes,maxInFlight,maxReadBytes}))
        if(!Number.isSafeInteger(value)||value<1)throw new RangeError(name);
      if(maxBytes<blockSize||typeof fetchRange!=='function')throw new TypeError('cache configuration');
      const blocks=new Map(),pending=new Map(),waiters=[],controller=new AbortController();
      let retainedBytes=0,active=0,disposed=false;
      const counters={reads:0,completedReads:0,failedReads:0,requestedBytes:0,hits:0,misses:0,coalesced:0,
        fetches:0,failedFetches:0,fetchedBytes:0,acceptedBytes:0,evictions:0,peakActive:0};
      const abortError=()=>new DOMException('Disc cache disposed','AbortError');
      const ensureOpen=()=>{if(disposed)throw abortError()};
      function acquire(){
        ensureOpen();
        if(active<maxInFlight){active++;counters.peakActive=Math.max(counters.peakActive,active);return Promise.resolve()}
        return new Promise((resolve,reject)=>waiters.push({resolve,reject}));
      }
      function release(){if(waiters.length&&!disposed)waiters.shift().resolve();else active--}
      async function fetchAbortable(start,length){
        ensureOpen();const signal=controller.signal;let onAbort;
        const cancellation=new Promise((_,reject)=>{onAbort=()=>reject(abortError());signal.addEventListener('abort',onAbort,{once:true})});
        try{return await Promise.race([Promise.resolve().then(()=>{ensureOpen();return fetchRange(start,length,signal)}),cancellation])}
        finally{signal.removeEventListener('abort',onAbort)}
      }
      async function block(start){
        ensureOpen();
        if(blocks.has(start)){counters.hits++;const data=blocks.get(start);blocks.delete(start);blocks.set(start,data);return data}
        if(pending.has(start)){counters.coalesced++;return pending.get(start)}
        counters.misses++;
        const promise=Promise.resolve().then(async()=>{
          await acquire();
          try{
            ensureOpen();counters.fetches++;
            const raw=await fetchAbortable(start,Math.min(blockSize,size-start));ensureOpen();
            if(!(raw instanceof Uint8Array))throw new TypeError('Disc response must be Uint8Array');
            counters.fetchedBytes+=raw.byteLength;
            if(raw.byteLength!==Math.min(blockSize,size-start))throw new Error('Disc response length mismatch');
            const data=new Uint8Array(raw);
            while(retainedBytes+data.length>maxBytes){const oldest=blocks.keys().next().value;retainedBytes-=blocks.get(oldest).length;blocks.delete(oldest);counters.evictions++}
            blocks.set(start,data);retainedBytes+=data.length;counters.acceptedBytes+=data.length;return data;
          }catch(error){counters.failedFetches++;throw error}
          finally{release()}
        });
        pending.set(start,promise);
        try{return await promise}finally{if(pending.get(start)===promise)pending.delete(start)}
      }
      async function read(offset,length){
        ensureOpen();
        if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<1||length>maxReadBytes||offset>size||length>size-offset)
          throw new RangeError('Invalid disc read');
        counters.reads++;counters.requestedBytes+=length;const output=new Uint8Array(length);
        try{
          for(let copied=0;copied<length;){
            const position=offset+copied,start=Math.floor(position/blockSize)*blockSize;
            const data=await block(start);ensureOpen();const within=position-start,count=Math.min(length-copied,data.length-within);
            output.set(data.subarray(within,within+count),copied);copied+=count;
          }
          counters.completedReads++;return output;
        }catch(error){counters.failedReads++;throw error}
      }
      function dispose(){if(disposed)return;disposed=true;blocks.clear();retainedBytes=0;controller.abort();for(const waiter of waiters.splice(0))waiter.reject(abortError())}
      return Object.freeze({read,dispose,stats:()=>({...counters,retainedBytes,blocks:blocks.size,pending:pending.size,active,queued:waiters.length,blockSize,maxBytes,maxInFlight,disposed})});
    }
    function createLoopbackRangeFetcher({url,size,fetchImpl=globalThis.fetch}) {
      const target=new URL(url);
      if(target.protocol!=='http:'||!['localhost','127.0.0.1','[::1]'].includes(target.hostname)||target.username||target.password||target.hash||!Number.isSafeInteger(size)||size<1)
        throw new TypeError('Expected fixed loopback disc URL and size');
      return async(offset,length,signal)=>{
        if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<1||offset>size||length>size-offset)throw new RangeError('Invalid HTTP disc range');
        const end=offset+length-1,response=await fetchImpl(target.href,{headers:{Range:`bytes=${offset}-${end}`},redirect:'error',credentials:'omit',cache:'no-store',signal});
        if(response.status!==206||response.redirected)throw new Error('Disc HTTP range response');
        if(response.headers.get('Content-Range')!==`bytes ${offset}-${end}/${size}`)throw new Error('Disc Content-Range mismatch');
        const raw=new Uint8Array(await response.arrayBuffer());if(raw.length!==length)throw new Error('Disc HTTP body length mismatch');return raw;
      };
    }

    // Private QA adapter. The core exposes a single done bit, so one logical read is allowed.
    function createQADiscDevice({owner,isCurrent,cache,size,onBegin=()=>null,onEnd=()=>{},onError=()=>{}}){
      let closed=false,active=false,pending=Promise.resolve();
      const validHeapRange=(heap,dst,length)=>heap instanceof Uint8Array&&Number.isSafeInteger(dst)&&Number.isSafeInteger(length)&&dst>=0&&length>=0&&dst<=heap.length&&length<=heap.length-dst;
      const device={done:true,getFileSize:()=>size,isDone(){return this.done},
        dispose(){if(closed)return;closed=true;cache.dispose()},
        settled:()=>pending,
        read(dst,offset,length){
          if(closed)return;
          if(!isCurrent(owner)){device.dispose();return}
          if(active){onError(new Error('Overlapping disc read unsupported by single-done ABI'));device.dispose();return}
          active=true;device.done=false;const begin=onBegin(offset,length);let received=0,ok=false;
          pending=(async()=>{
            try{
              if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<0||offset>size||length>size-offset||!validHeapRange(owner.HEAPU8,dst,length))throw new RangeError('Invalid disc device read');
              for(let copied=0;copied<length;){
                const count=Math.min(1048576,length-copied),bytes=await cache.read(offset+copied,count);
                if(closed)return;
                if(!isCurrent(owner)){device.dispose();return}
                // Fetch a fresh HEAPU8 after await: WASM memory may have grown.
                const heap=owner.HEAPU8;if(!validHeapRange(heap,dst,length))throw new RangeError('Disc heap changed');
                heap.set(bytes,dst+copied);copied+=count;received+=count;
              }
              ok=true;
            }catch(error){
              if(!closed&&isCurrent(owner)){
                onError(error);const heap=owner.HEAPU8;if(validHeapRange(heap,dst,length))heap.fill(0,dst,dst+length);
              }
            }finally{active=false;device.done=true;onEnd(begin,received,ok)}
          })();
        }
      };
      return Object.seal(device);
    }

    const config=__CONFIG__,canvas=document.querySelector('canvas'),startButton=document.querySelector('#start'),status=document.querySelector('#status');
    const discCacheEnabled=config.qa===true&&config.qaDiscCache===true;let discCache=null,qaDiscDevice=null;
    // QA counters contain no disc data or paths. Constant-size accumulators;
    // no per-read event list and no additional GPU readback.
    const qa=config.qa?{startedMs:performance.now(),phase:"module",http:qaCounters(),disc:qaCounters(),
      image:{samples:0,changes:0,fingerprint:null,changedBetweenSamples:null,lastSampleMs:null,readbackMs:0,analysisMs:0}}:null;
    function qaCounters(){return {count:0,completed:0,failed:0,requestedBytes:0,receivedBytes:0,totalMs:0,maxMs:0,lastMs:0,
      inFlight:0,busyMs:0,busySinceMs:null,lastOffset:null,lastLength:0,sequential:0,repeated:0,durationBuckets:[0,0,0,0,0]}}
    function qaBegin(stats,offset,length){
      if(!stats)return null;const now=performance.now();
      if(stats.lastOffset!==null){if(offset===stats.lastOffset+stats.lastLength)stats.sequential++;if(offset===stats.lastOffset&&length===stats.lastLength)stats.repeated++}
      stats.count++;stats.requestedBytes+=length;stats.lastOffset=offset;stats.lastLength=length;
      if(stats.inFlight++===0)stats.busySinceMs=now;return now;
    }
    function qaEnd(stats,start,received,ok){
      if(!stats)return;const now=performance.now(),ms=Math.max(0,now-start);
      stats.completed+=ok?1:0;stats.failed+=ok?0:1;stats.receivedBytes+=received;stats.totalMs+=ms;stats.maxMs=Math.max(stats.maxMs,ms);stats.lastMs=ms;
      stats.durationBuckets[ms<1?0:ms<4?1:ms<16?2:ms<64?3:4]++;
      if(--stats.inFlight===0){stats.busyMs+=Math.max(0,now-stats.busySinceMs);stats.busySinceMs=null}
    }
    function qaSnapshot(){
      const now=performance.now(),stats=value=>({...value,durationBuckets:[...value.durationBuckets],
        busyMs:value.busyMs+(value.busySinceMs===null?0:Math.max(0,now-value.busySinceMs))});
      return {schema:1,timeMs:now,elapsedMs:now-qa.startedMs,phase:qa.phase,started,paused,broken,hidden:document.hidden,
        http:stats(qa.http),disc:stats(qa.disc),image:{...qa.image},
        imageScope:"1Hz sampled changes; not unique FPS",gameClock:null,discCache:discCache?.stats()??null};
    }
    function qaImage(bytes,readbackMs){
      if(!qa)return;const begin=performance.now();let hash=2166136261;
      // 32x24 fixed pixel samples from the SAME existing 640x480 readback.
      for(let y=10;y<480;y+=20)for(let x=10;x<640;x+=20){const i=(y*640+x)*4;for(let c=0;c<4;c++)hash=Math.imul(hash^bytes[i+c],16777619)>>>0}
      const fingerprint=hash.toString(16).padStart(8,'0'),image=qa.image;
      image.changedBetweenSamples=image.fingerprint===null?null:image.fingerprint!==fingerprint;
      if(image.changedBetweenSamples)image.changes++;image.samples++;image.fingerprint=fingerprint;
      image.lastSampleMs=performance.now();image.readbackMs=readbackMs;image.analysisMs=image.lastSampleMs-begin;
    }
    const report=value=>{if(qa){if(value.phase)qa.phase=value.phase;if(value.stage)qa.phase=value.stage;if(value.error)qa.phase="error"}window.webkit.messageHandlers.veta.postMessage(value)};
    let phase="module",module,broken=false,errorReported=false,paused=true,chain=Promise.resolve(),started=false,interrupted=false;
    const contexts=[];
    if(qa)setInterval(()=>report({qaTelemetry:qaSnapshot()}),1000);
    const AudioBase=window.AudioContext||window.webkitAudioContext;
    if(AudioBase){class TrackedAudio extends AudioBase{constructor(...args){super(...args);contexts.push(this)}resume(){return super.resume().catch(error=>{report({audioWarning:String(error)})})}}window.AudioContext=TrackedAudio;window.webkitAudioContext=TrackedAudio}
    const fail=error=>{if(errorReported)return;errorReported=true;broken=true;report({error:phase+": "+String(error)});status.textContent=config.failure};
    document.addEventListener('visibilitychange',()=>{if(document.hidden)interrupted=true});
    window.addEventListener('error',e=>fail(e.message));window.addEventListener('unhandledrejection',e=>fail(e.reason));
    if(config.qa){const original=canvas.getContext.bind(canvas);canvas.getContext=(kind,attrs)=>original(kind,kind.startsWith('webgl')?{...attrs,preserveDrawingBuffer:true}:attrs)}
    const request=async(path,options)=>{const response=await fetch(new URL(path,location.href),options);if(!response.ok)throw Error('Storage '+response.status);return response};
    const serial=fn=>{const next=chain.then(()=>{if(broken)throw Error('Session needs restart');return fn()});chain=next.catch(()=>{});return next};
    async function operation(id){if(!id)throw Error('Operation rejected');const end=performance.now()+30000;for(;;){const result=module.pollOperation(id);if(result===1)return;if(result<0)throw Error('Operation failed '+result);if(performance.now()>end){broken=true;throw Error('Operation timeout; restart session')}await new Promise(r=>setTimeout(r,16))}}
    class AudioRecoveryError extends Error {}
    async function pause(value){
      module.resetInput();
      if(value){await operation(module.setPaused(true));paused=true;for(const context of contexts)context.suspend().catch(error=>report({audioWarning:String(error)}));return}
      // Audio interruptions are recoverable. Keep the VM paused until audio is available.
      await operation(module.setPaused(true));paused=true;
      for(const context of contexts){
        let timer;try{await Promise.race([context.resume(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new AudioRecoveryError('Audio resume timed out')),5000)})])}finally{clearTimeout(timer)}
        if(context.state!=='running')throw new AudioRecoveryError('Audio unavailable: '+context.state);
      }
      if(document.hidden)throw new AudioRecoveryError('Session is in background');
      await operation(module.setPaused(false));paused=false;interrupted=false;
    }
    function mkdir(path){try{module.FS.mkdirTree(path)}catch(e){if(!module.FS.analyzePath(path).exists)throw e}}
    const validPath=path=>typeof path==='string'&&/^vfs\/mc[01]\//.test(path)&&!path.split('/').some(p=>!p||p==='.'||p==='..'||p.includes('\\'));
    const encodePath=path=>path.split('/').map(encodeURIComponent).join('/');
    async function restoreCards(){
      const index=await (await request('storage-index')).json();const files=Array.isArray(index)?index:index.files;
      if(!Array.isArray(files)||files.length>10000)throw Error('Invalid storage index');
      const root=module.getDataPath();let total=0;
      for(const entry of files){if(!validPath(entry.path)||!Number.isSafeInteger(entry.size)||entry.size<0||(total+=entry.size)>134217728)throw Error('Invalid storage entry');const bytes=new Uint8Array(await (await request('storage/'+encodePath(entry.path))).arrayBuffer());if(bytes.length!==entry.size)throw Error('Short storage file');const path=root+'/'+entry.path;mkdir(path.slice(0,path.lastIndexOf('/')));module.FS.writeFile(path,bytes)}
    }
    async function persistCards(){
      const files=[],root=module.getDataPath();let total=0;
      function walk(relative,depth){if(depth>16||files.length>10000)throw Error('Storage tree limit');const path=root+'/'+relative;if(!module.FS.analyzePath(path).exists)return;for(const name of module.FS.readdir(path)){if(name==='.'||name==='..')continue;const next=relative+'/'+name,stat=module.FS.stat(root+'/'+next);if(module.FS.isDir(stat.mode))walk(next,depth+1);else{if(!validPath(next)||stat.size>67108864||(total+=stat.size)>134217728)throw Error('Storage size limit');files.push({path:next,size:stat.size})}}}
      walk('vfs/mc0',0);walk('vfs/mc1',0);
      await request('storage-begin',{method:'PUT',body:new Uint8Array()});
      for(const file of files){const bytes=module.FS.readFile(root+'/'+file.path);await request('storage/'+encodePath(file.path),{method:'PUT',headers:{'Content-Type':'application/octet-stream'},body:bytes})}
      await request('storage-index',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({files})});
    }
    async function save(slot){
      if(!['auto','quick','before-load'].includes(slot)&&!/^slot[1-8]$/.test(slot))throw Error('Invalid slot');
      await pause(true);const path='/work/'+slot+'.zip';
      try{await operation(module.saveState(path));await persistCards();await request('state/'+slot,{method:'PUT',headers:{'Content-Type':'application/octet-stream'},body:module.FS.readFile(path)});if(slot==='quick')report({quick:true})}
      finally{try{module.FS.unlink(path)}catch{}}
    }
    async function load(slot,recovery=true){
      if(!['auto','quick'].includes(slot)&&!/^slot[1-8]$/.test(slot))throw Error('Invalid slot');await pause(true);
      const bytes=new Uint8Array(await (await request('state/'+slot)).arrayBuffer());
      if(recovery)await save('before-load');const path='/work/load.zip';module.FS.writeFile(path,bytes);
      try{await operation(module.loadState(path))}
      catch(error){broken=true;throw error}
      finally{try{module.FS.unlink(path)}catch{}}
    }
    const buttonMap=[13,10,8,9,4,5,6,7,12,11,14,17,15,18,16,19];
    window.veta={
      interrupt:()=>{interrupted=true},pause:value=>serial(()=>pause(value)),save:slot=>serial(()=>save(slot)),load:slot=>serial(()=>load(slot)),
      input:ports=>{if(!module||broken||paused)return;for(let port=0;port<Math.min(2,ports.length);port++){const [mask,...axes]=ports[port];for(let bit=0;bit<16;bit++)module.setInputButton(port,buttonMap[bit],Boolean(mask&(1<<bit)));for(let axis=0;axis<4;axis++)module.setInputAxis(port,axis,axes[axis]||0)}}
    };
    async function range(offset,length){
      if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<1||offset+length>config.size)throw Error('Invalid disc read');
      const begin=qaBegin(qa?.http,offset,length);let received=0,ok=false;
      try{
        const response=await fetch(new URL('disc',location.href),{headers:{Range:`bytes=${offset}-${offset+length-1}`}});if(response.status!==206)throw Error('Disc read '+response.status);
        const bytes=new Uint8Array(await response.arrayBuffer());received=bytes.length;if(bytes.length!==length)throw Error('Short disc read');ok=true;return bytes;
      }finally{qaEnd(qa?.http,begin,received,ok)}
    }
    try{
      if(discCacheEnabled){
        const fetchRange=createLoopbackRangeFetcher({url:new URL('disc',location.href).href,size:config.size,fetchImpl:fetch});
        discCache=createDiscRangeCache({size:config.size,blockSize:65536,maxBytes:4194304,maxInFlight:4,
          fetchRange:async(offset,length,signal)=>{const begin=qaBegin(qa.http,offset,length);let received=0,ok=false;
            try{const bytes=await fetchRange(offset,length,signal);received=bytes.length;ok=true;return bytes}
            finally{qaEnd(qa.http,begin,received,ok)}}});
        const dispose=()=>{qaDiscDevice?.dispose();discCache.dispose()};
        window.veta.disposeDiscCache=dispose;window.addEventListener('pagehide',dispose,{once:true});
      }
      if(!isSecureContext||!crossOriginIsolated||typeof SharedArrayBuffer!=='function')throw Error('Local execution unavailable');
      const {default:Play}=await import('./Play.js');module=await Play({locateFile:p=>new URL(p,location.href).href,mainScriptUrlOrBlob:new URL('Play.js',location.href).href,onAbort:e=>fail('Emulator stopped: '+e)});
      if(module.getStateFormat()!=='play-505dac7-vmzip-timing-v1')throw Error('Wrong emulator state format');
      module.setResolutionFactor(1);mkdir('/work');
      if(discCache){qaDiscDevice=createQADiscDevice({owner:module,isCurrent:owner=>module===owner,cache:discCache,size:config.size,
        onBegin:(offset,length)=>qaBegin(qa.disc,offset,length),onEnd:(begin,received,ok)=>qaEnd(qa.disc,begin,received,ok),onError:fail});module.discImageDevice=qaDiscDevice}
      else module.discImageDevice={done:true,getFileSize:()=>config.size,isDone(){return this.done},read(dst,offset,size){this.done=false;const begin=qaBegin(qa?.disc,offset,size);let received=0,ok=false;(async()=>{try{for(let done=0;done<size;){const count=Math.min(1048576,size-done),bytes=await range(offset+done,count);module.HEAPU8.set(bytes,dst+done);done+=count;received+=count}ok=true}catch(e){fail(e);module.HEAPU8.fill(0,dst,dst+size)}finally{this.done=true;qaEnd(qa?.disc,begin,received,ok)}})()}};
      module.ccall('initVm','',[],[]);await restoreCards();
      const states=await (await request('state-index')).json();report({stage:'ready',quick:states.quick===true,recovered:Array.isArray(states.recovered)&&states.recovered.length>0});startButton.textContent=config.play;startButton.hidden=false;
      startButton.onclick=async()=>{
        if(started||broken)return;started=true;startButton.hidden=true;status.textContent=config.loading;
        try{
          phase="audio-unlock";report({phase});for(const context of contexts)context.resume();
          phase="disc-read";report({phase});
          if(config.name.toLowerCase().endsWith('.elf')){if(config.size>33554432)throw Error('ELF size limit');const fd=module.FS.open('/work/game.elf','w');try{for(let offset=0;offset<config.size;){const bytes=await range(offset,Math.min(1048576,config.size-offset));module.FS.write(fd,bytes,0,bytes.length,offset);offset+=bytes.length}}finally{module.FS.close(fd)}module.bootElf('/work/game.elf')}
          else module.bootDiscImage(config.name);
          phase="first-frame";report({phase});const deadline=performance.now()+90000;while(module.getFrames()<1){if(broken||performance.now()>deadline)throw Error('Game startup timeout');await new Promise(r=>setTimeout(r,50))}
          phase="auto-restore";report({phase});if(states.auto===true)await load('auto',false);phase="resume";report({phase});
          if(interrupted||document.hidden)await pause(true);
          else {try{await pause(false)}catch(error){if(!(error instanceof AudioRecoveryError))throw error;await pause(true);report({audioWarning:String(error)})}}
          status.textContent='';report({stage:'running',paused,restoredAuto:states.auto===true});
          let previous=module.getFrames(),last=performance.now();
          setInterval(()=>{if(broken)return;const now=performance.now(),frames=module.getFrames();let colors=0,playerX=-1,playerPixels=0;
            if(config.qa){const gl=canvas.getContext('webgl2'),old=gl.getParameter(gl.FRAMEBUFFER_BINDING);gl.bindFramebuffer(gl.FRAMEBUFFER,null);const bytes=new Uint8Array(640*480*4);const readbackBegin=performance.now();gl.readPixels(0,0,640,480,gl.RGBA,gl.UNSIGNED_BYTE,bytes);const readbackMs=performance.now()-readbackBegin;gl.bindFramebuffer(gl.FRAMEBUFFER,old);qaImage(bytes,readbackMs);const set=new Set();for(let n=0;n<bytes.length;n+=256){set.add((bytes[n]<<16)|(bytes[n+1]<<8)|bytes[n+2]);if(set.size>64)break}colors=set.size;let sum=0;for(let y=230;y<331;y++)for(let x=89;x<192;x++){const i=((479-y)*640+x)*4;if(bytes[i]>180&&bytes[i+1]>120&&bytes[i+2]<100){sum+=x;playerPixels++}}if(playerPixels>10)playerX=sum/playerPixels}
            report({frames,playerX,playerPixels,fps:(frames-previous)*1000/(now-last),colors,paused,audio:contexts.map(c=>c.state).join(',')});previous=frames;last=now;
          },1000);
        }catch(e){fail(e)}
      };
    }catch(e){fail(e)}
    </script></body></html>
    """#
}
#endif
