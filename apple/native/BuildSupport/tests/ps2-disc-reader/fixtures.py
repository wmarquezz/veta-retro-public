from pathlib import Path
import struct,zlib,random,json,sys
A=Path(sys.argv[1]);A.mkdir(parents=True,exist_ok=True);manifest={}
def raw(data):
 c=zlib.compressobj(6,zlib.DEFLATED,-15);return c.compress(data)+c.flush()
def write(name,data,stage):
 (A/name).write_bytes(data);manifest[name]=stage
rng=random.Random(160)
plain=b''.join((bytes([i%256])*2048 if i%3 else rng.randbytes(2048)) for i in range(150));write('reference.iso',plain,'good')
def build(payload,shift=0,custom=None,blockSize=2048):
 n=(len(payload)+blockSize-1)//blockSize;a=1<<shift;start=24+4*(n+1);body=bytearray(b'\0'*((-start)%a));index=[]
 for i in range(n):
  b=payload[i*blockSize:(i+1)*blockSize];packed=raw(b);stored=len(packed)>=len(b)
  if custom is not None:packed=custom;stored=False
  index.append(((start+len(body))>>shift)|(0x80000000 if stored else 0));body+=b if stored else packed;body+=b'\0'*((-(start+len(body)))%a)
 index.append((start+len(body))>>shift)
 return struct.pack('<4sIQIBBH',b'CISO',24,len(payload),blockSize,1,shift,0)+struct.pack('<'+'I'*len(index),*index)+body
for shift in [0,2,16]:write('good-'+str(shift)+'.cso',build(plain,shift),'good')
for blockSize in [4096,8192,16384,32768,65536]:write('good-block-'+str(blockSize)+'.cso',build(plain,1,blockSize=blockSize),'good')
partial=rng.randbytes(6144);write('plain-partial.iso',partial,'good');write('plain-partial.cso',build(partial,2,blockSize=16384),'good')
base=build(b'A'*2048)
write('short-header.cso',base[:23],'init');write('bad-magic.cso',b'BAD!'+base[4:],'init')
for name,offset,fmt,value in [('header-size',4,'I',0),('zero-logical',8,'Q',0),('over-logical',8,'Q',8*1024**3+2048),('partial-sector',8,'Q',2049),('wrong-sector',16,'I',1536),('version2',20,'B',2),('shift17',21,'B',17),('reserved',22,'H',1),('inside-table',24,'I',24),('outside-file',28,'I',0x7fffffff),('sentinel-flag',28,'I',0x80000000|len(base)),('duplicate-offset',28,'I',32),('descending-offset',28,'I',31),('short-stored',24,'I',0x80000000|32)]:
 data=bytearray(base);struct.pack_into('<'+fmt,data,offset,value);write(name+'.cso',data,'init')
write('table-truncated.cso',base[:28],'init')
for name,data in [('deflate-invalid',b'\xff'*8),('zlib-wrapped',zlib.compress(b'A'*2048)),('short-output',raw(b'A'*2047)),('long-output',raw(b'A'*2049)),('truncated-stream',raw(b'A'*2048)[:-1]),('trailing-stream',raw(b'A'*2048)+b'\0')]:write(name+'.cso',build(b'A'*2048,custom=data),'read')
write('empty.iso',b'','init')
(A/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(len(manifest),'fixtures')
