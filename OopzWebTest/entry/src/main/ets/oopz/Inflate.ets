// Minimal zlib/DEFLATE inflater (port of tinf / tiny-inflate).
// Needed to read the Agora AccessToken2 hidden in Oopz's supplierSign:
//   "007" + base64( zlib(def payload) ), payload[0..3] = uint32BE length of appId.

class InflateTree {
  table: Uint16Array = new Uint16Array(16);
  trans: Uint16Array = new Uint16Array(288);
}

class InflateState {
  source: Uint8Array;
  sourceIndex: number;
  tag: number;
  bitcount: number;
  dest: Uint8Array;
  destLen: number = 0;
  ltree: InflateTree = new InflateTree();
  dtree: InflateTree = new InflateTree();

  constructor(source: Uint8Array, dest: Uint8Array, start: number) {
    this.source = source;
    this.sourceIndex = start;
    this.tag = 0;
    this.bitcount = 0;
    this.dest = dest;
  }
}

const SLTREE: InflateTree = new InflateTree();
const SDTREE: InflateTree = new InflateTree();
const LENGTH_BITS: Uint8Array = new Uint8Array(30);
const LENGTH_BASE: Uint16Array = new Uint16Array(30);
const DIST_BITS: Uint8Array = new Uint8Array(30);
const DIST_BASE: Uint16Array = new Uint16Array(30);
const CLCIDX: Uint8Array = new Uint8Array([16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]);
const CODE_TREE: InflateTree = new InflateTree();
const LENGTHS: Uint8Array = new Uint8Array(320);
const OFFS: Uint16Array = new Uint16Array(16);

function buildBitsBase(bits: Uint8Array, base: Uint16Array, delta: number, first: number): void {
  for (let i = 0; i < delta; ++i) {
    bits[i] = 0;
  }
  for (let i = 0; i < 30 - delta; ++i) {
    bits[i + delta] = Math.floor(i / delta);
  }
  let sum = first;
  for (let i = 0; i < 30; ++i) {
    base[i] = sum;
    sum += 1 << bits[i];
  }
}

function buildFixedTrees(lt: InflateTree, dt: InflateTree): void {
  for (let i = 0; i < 7; ++i) {
    lt.table[i] = 0;
  }
  lt.table[7] = 24;
  lt.table[8] = 152;
  lt.table[9] = 112;
  for (let i = 0; i < 24; ++i) {
    lt.trans[i] = 256 + i;
  }
  for (let i = 0; i < 144; ++i) {
    lt.trans[24 + i] = i;
  }
  for (let i = 0; i < 8; ++i) {
    lt.trans[24 + 144 + i] = 280 + i;
  }
  for (let i = 0; i < 112; ++i) {
    lt.trans[24 + 144 + 8 + i] = 144 + i;
  }
  for (let i = 0; i < 5; ++i) {
    dt.table[i] = 0;
  }
  dt.table[5] = 32;
  for (let i = 0; i < 32; ++i) {
    dt.trans[i] = i;
  }
}

function buildTree(t: InflateTree, lengths: Uint8Array, off: number, num: number): void {
  for (let i = 0; i < 16; ++i) {
    t.table[i] = 0;
  }
  for (let i = 0; i < num; ++i) {
    t.table[lengths[off + i]]++;
  }
  t.table[0] = 0;
  let sum = 0;
  for (let i = 0; i < 16; ++i) {
    OFFS[i] = sum;
    sum += t.table[i];
  }
  for (let i = 0; i < num; ++i) {
    const len = lengths[off + i];
    if (len) {
      t.trans[OFFS[len]++] = i;
    }
  }
}

function byteAt(d: InflateState): number {
  const idx = d.sourceIndex;
  d.sourceIndex = idx + 1;
  return idx < d.source.length ? d.source[idx] : 0;
}

function getBit(d: InflateState): number {
  if (d.bitcount === 0) {
    d.tag = byteAt(d);
    d.bitcount = 7;
  } else {
    d.bitcount--;
  }
  const bit = d.tag & 1;
  d.tag >>>= 1;
  return bit;
}

function readBits(d: InflateState, num: number, base: number): number {
  if (num === 0) {
    return base;
  }
  while (d.bitcount < 24) {
    d.tag |= byteAt(d) << d.bitcount;
    d.bitcount += 8;
  }
  const val = d.tag & (0xffff >>> (16 - num));
  d.tag >>>= num;
  d.bitcount -= num;
  return val + base;
}

function decodeSymbol(d: InflateState, t: InflateTree): number {
  while (d.bitcount < 24) {
    d.tag |= byteAt(d) << d.bitcount;
    d.bitcount += 8;
  }
  let sum = 0;
  let cur = 0;
  let len = 0;
  let tag = d.tag;
  do {
    cur = 2 * cur + (tag & 1);
    tag >>>= 1;
    ++len;
    sum += t.table[len];
    cur -= t.table[len];
  } while (cur >= 0);
  d.tag = tag;
  d.bitcount -= len;
  return t.trans[sum + cur];
}

function decodeTrees(d: InflateState, lt: InflateTree, dt: InflateTree): void {
  const hlit = readBits(d, 5, 257);
  const hdist = readBits(d, 5, 1);
  const hclen = readBits(d, 4, 4);

  for (let i = 0; i < 19; ++i) {
    LENGTHS[i] = 0;
  }
  for (let i = 0; i < hclen; ++i) {
    LENGTHS[CLCIDX[i]] = readBits(d, 3, 0);
  }
  buildTree(CODE_TREE, LENGTHS, 0, 19);

  let num = 0;
  while (num < hlit + hdist) {
    const sym = decodeSymbol(d, CODE_TREE);
    if (sym === 16) {
      const prev = LENGTHS[num - 1];
      let length = readBits(d, 2, 3);
      while (length > 0) {
        LENGTHS[num++] = prev;
        length--;
      }
    } else if (sym === 17) {
      let length = readBits(d, 3, 3);
      while (length > 0) {
        LENGTHS[num++] = 0;
        length--;
      }
    } else if (sym === 18) {
      let length = readBits(d, 7, 11);
      while (length > 0) {
        LENGTHS[num++] = 0;
        length--;
      }
    } else {
      LENGTHS[num++] = sym;
    }
  }
  buildTree(lt, LENGTHS, 0, hlit);
  buildTree(dt, LENGTHS, hlit, hdist);
}

function inflateBlockData(d: InflateState, lt: InflateTree, dt: InflateTree): void {
  while (true) {
    let sym = decodeSymbol(d, lt);
    if (sym === 256) {
      return;
    }
    if (sym < 256) {
      d.dest[d.destLen++] = sym;
    } else {
      sym -= 257;
      const length = readBits(d, LENGTH_BITS[sym], LENGTH_BASE[sym]);
      const dist = decodeSymbol(d, dt);
      const offs = d.destLen - readBits(d, DIST_BITS[dist], DIST_BASE[dist]);
      for (let i = offs; i < offs + length; ++i) {
        d.dest[d.destLen++] = d.dest[i];
      }
    }
  }
}

function inflateUncompressedBlock(d: InflateState): number {
  while (d.bitcount > 8) {
    d.sourceIndex--;
    d.bitcount -= 8;
  }
  let length = d.source[d.sourceIndex + 1];
  length = 256 * length + d.source[d.sourceIndex];
  let invlength = d.source[d.sourceIndex + 3];
  invlength = 256 * invlength + d.source[d.sourceIndex + 2];
  if (length !== ((~invlength) & 0x0000ffff)) {
    return -3;
  }
  d.sourceIndex += 4;
  for (let i = length; i > 0; --i) {
    d.dest[d.destLen++] = d.source[d.sourceIndex++];
  }
  d.bitcount = 0;
  return 0;
}

export function inflateZlib(data: Uint8Array): Uint8Array {
  let start = 0;
  if (data.length >= 2) {
    const cmf = data[0];
    const flg = data[1];
    if ((cmf & 0x0f) === 8 && (((cmf << 8) | flg) % 31) === 0) {
      start = 2;
    }
  }
  const dest = new Uint8Array(65536);
  const d = new InflateState(data, dest, start);
  let bfinal = 0;
  do {
    bfinal = getBit(d);
    const btype = readBits(d, 2, 0);
    let res = 0;
    if (btype === 0) {
      res = inflateUncompressedBlock(d);
    } else if (btype === 1) {
      inflateBlockData(d, SLTREE, SDTREE);
    } else if (btype === 2) {
      decodeTrees(d, d.ltree, d.dtree);
      inflateBlockData(d, d.ltree, d.dtree);
    } else {
      res = -3;
    }
    if (res !== 0) {
      throw new Error('inflate data error');
    }
  } while (bfinal === 0);
  return dest.subarray(0, d.destLen);
}

buildFixedTrees(SLTREE, SDTREE);
buildBitsBase(LENGTH_BITS, LENGTH_BASE, 4, 3);
buildBitsBase(DIST_BITS, DIST_BASE, 2, 1);
LENGTH_BITS[28] = 0;
LENGTH_BASE[28] = 258;
