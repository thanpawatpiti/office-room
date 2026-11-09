'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
module.exports = function imageAttachments(dataDirectory) {
  const directory = path.join(dataDirectory, 'images');
  fs.mkdirSync(directory, { recursive: true });
  function resolve(ids = []) {
    if (!Array.isArray(ids) || ids.length > 4) throw new Error('แนบภาพได้ไม่เกิน 4 รูปต่อข้อความ');
    return ids.map(id => {
      if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/.test(id)) throw new Error('รหัสภาพไม่ถูกต้อง');
      const file = path.join(directory, id + '.png');
      if (!fs.existsSync(file)) throw new Error('ไม่พบภาพแนบ กรุณาแนบใหม่');
      return { id, name: 'ภาพแนบ.png', path: file };
    });
  }
  function save(base64) {
    if (typeof base64 !== 'string' || base64.length > 12 * 1024 * 1024 || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64)) throw new Error('ข้อมูลภาพไม่ถูกต้องหรือใหญ่เกินไป');
    const png = Buffer.from(base64, 'base64');
    if (png.length < 33 || png.length > 8 * 1024 * 1024 || !png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) || png.toString('ascii',12,16) !== 'IHDR') throw new Error('รองรับภาพ PNG ขนาดไม่เกิน 8 MB');
    const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
    if (!width || !height || width * height > 40_000_000) throw new Error('ภาพมีขนาดใหญ่เกินไป');
    const id = crypto.randomUUID(); fs.writeFileSync(path.join(directory, id + '.png'), png, { mode: 0o600 });
    return resolve([id])[0];
  }
  return { save, resolve };
};
