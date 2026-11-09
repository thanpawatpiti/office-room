Office Room — วิธีติดตั้ง

1. ลาก "Office Room.app" ไปไว้ในโฟลเดอร์ Applications
2. เปิดครั้งแรก macOS จะเตือนว่าตรวจสอบผู้พัฒนาไม่ได้ (แอปนี้ไม่ได้ลงทะเบียนกับ Apple)
   ให้กด Done แล้วไปที่ System Settings > Privacy & Security
   เลื่อนลงไปจะเจอ "Office Room was blocked..." กด Open Anyway แล้วใส่รหัสเครื่อง
   (ทำครั้งเดียว ครั้งต่อไปเปิดได้ปกติ)

   หรือเปิด Terminal แล้วรันคำสั่งนี้ทีเดียวจบ:
     xattr -dr com.apple.quarantine "/Applications/Office Room.app"

สิ่งที่ต้องมีในเครื่อง
- macOS 13 ขึ้นไป (ใช้ได้ทั้ง Apple Silicon และ Intel)
- ไม่ต้องติดตั้ง Node.js เพราะมีมาในแอปแล้ว
- ต้องมี Claude Code หรือ Codex อย่างใดอย่างหนึ่ง และ login ไว้แล้ว
  จะติดตั้งแบบ CLI ก็ได้ หรือมีแค่แอป Claude Desktop / Codex (หรือ ChatGPT) ก็ได้
  แอปจะหา CLI ที่มาพร้อมแอป desktop เอง
  ถ้าใช้แอป desktop ให้เปิดแอปนั้นและเข้าหน้า Code อย่างน้อยหนึ่งครั้งก่อน

ข้อมูลของแอป (ห้อง, ตั้งค่า, log) เก็บที่ ~/.office-room/data
