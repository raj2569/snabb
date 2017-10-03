-- Implementation of ESP over IPv6 using AES-128-GCM using a 12 byte ICV and
-- “Extended Sequence Number” (see RFC 4303 and RFC 4106).
--
-- Notes:
--
--  * Wrapping around of the Extended Sequence Number is *not* detected because
--    it is assumed to be an unrealistic scenario as it would take 584 years to
--    overflow the counter when transmitting 10^9 packets per second.
--
--  * Rejection of IP fragments is *not* implemented because
--    `lib.protocol.ipv6' does not support fragmentation. E.g. fragments will
--    be rejected because they can not be parsed as IPv6 packets. If however
--    `lib.protocol.ipv6' were to be updated to be able to parse IP fragments
--    this implementation would have to be updated as well to remain correct.
--    See the “Reassembly” section of RFC 4303 for details:
--    https://tools.ietf.org/html/rfc4303#section-3.4.1
--
module(..., package.seeall)
local header = require("lib.protocol.header")
local datagram = require("lib.protocol.datagram")
local ethernet = require("lib.protocol.ethernet")
local ipv6 = require("lib.protocol.ipv6")
local esp = require("lib.protocol.esp")
local esp_tail = require("lib.protocol.esp_tail")
local aes_128_gcm = require("lib.ipsec.aes_128_gcm")
local seq_no_t = require("lib.ipsec.seq_no_t")
local lib = require("core.lib")
local ffi = require("ffi")
local C = ffi.C
local logger = lib.logger_new({ rate = 32, module = 'esp' });

require("lib.ipsec.track_seq_no_h")
local window_t = ffi.typeof("uint8_t[?]")

local ETHERNET_SIZE = ethernet:sizeof()
local IPV6_SIZE = ipv6:sizeof()
local PAYLOAD_OFFSET = ETHERNET_SIZE + IPV6_SIZE
local ESP_NH = 50 -- https://tools.ietf.org/html/rfc4303#section-2
local ESP_SIZE = esp:sizeof()
local ESP_TAIL_SIZE = esp_tail:sizeof()

function esp_v6_new (conf)
   assert(conf.mode == "aes-128-gcm", "Only supports aes-128-gcm.")
   assert(conf.spi, "Need SPI.")
   local gcm = aes_128_gcm:new(conf.spi, conf.key, conf.salt)
   local o = {}
   o.ESP_OVERHEAD = ESP_SIZE + ESP_TAIL_SIZE + gcm.IV_SIZE + gcm.AUTH_SIZE
   o.aes_128_gcm = gcm
   o.spi = conf.spi
   o.seq = ffi.new(seq_no_t)
   o.pad_to = 4 -- minimal padding
   o.ip = ipv6:new({})
   o.esp = esp:new({})
   o.esp_tail = esp_tail:new({})
   return o
end

esp_v6_encrypt = {}

function esp_v6_encrypt:new (conf)
   local o = esp_v6_new(conf)
   o.ESP_PAYLOAD_OVERHEAD =  o.aes_128_gcm.IV_SIZE + ESP_TAIL_SIZE
   return setmetatable(o, {__index=esp_v6_encrypt})
end

-- Increment sequence number.
function esp_v6_encrypt:next_seq_no ()
   self.seq.no = self.seq.no + 1
end

local function padding (a, l) return (a - l%a) % a end

-- Encapsulation is performed as follows:
--   1. Grow p to fit ESP overhead
--   2. Append ESP trailer to p
--   3. Encrypt payload+trailer in place
--   4. Move resulting ciphertext to make room for ESP header
--   5. Write ESP header
function esp_v6_encrypt:encapsulate (p)
   local gcm = self.aes_128_gcm
   local data, length = p.data, p.length
   if length < PAYLOAD_OFFSET then return false end
   local payload = data + PAYLOAD_OFFSET
   local payload_length = length - PAYLOAD_OFFSET
   -- Padding, see https://tools.ietf.org/html/rfc4303#section-2.4
   local pad_length = padding(self.pad_to, payload_length + self.ESP_PAYLOAD_OVERHEAD)
   local overhead = self.ESP_OVERHEAD + pad_length
   packet.resize(p, length + overhead)
   self.ip:new_from_mem(data + ETHERNET_SIZE, IPV6_SIZE)
   self.esp_tail:new_from_mem(data + length + pad_length, ESP_TAIL_SIZE)
   assert(self.ip and self.esp_tail)
   self.esp_tail:next_header(self.ip:next_header())
   self.esp_tail:pad_length(pad_length)
   self:next_seq_no()
   local ptext_length = payload_length + pad_length + ESP_TAIL_SIZE
   gcm:encrypt(payload, self.seq, self.seq:low(), self.seq:high(), payload, ptext_length, payload + ptext_length)
   local iv = payload + ESP_SIZE
   local ctext = iv + gcm.IV_SIZE
   C.memmove(ctext, payload, ptext_length + gcm.AUTH_SIZE)
   self.esp:new_from_mem(payload, ESP_SIZE)
   assert(self.esp)
   self.esp:spi(self.spi)
   self.esp:seq_no(self.seq:low())
   ffi.copy(iv, self.seq, gcm.IV_SIZE)
   self.ip:next_header(ESP_NH)
   self.ip:payload_length(payload_length + overhead)
   return true
end


esp_v6_decrypt = {}

function esp_v6_decrypt:new (conf)
   local o = esp_v6_new(conf)
   local gcm = o.aes_128_gcm
   o.MIN_SIZE = o.ESP_OVERHEAD + padding(o.pad_to, o.ESP_OVERHEAD)
   o.CTEXT_OFFSET = ESP_SIZE + gcm.IV_SIZE
   o.PLAIN_OVERHEAD = PAYLOAD_OFFSET + ESP_SIZE + gcm.IV_SIZE + gcm.AUTH_SIZE
   o.window_size = conf.window_size or 128
   o.window_size = o.window_size + padding(8, o.window_size)
   o.resync_threshold = conf.resync_threshold or 1024
   o.resync_attempts = conf.resync_attempts or 8
   o.window = ffi.new(window_t, o.window_size / 8)
   o.decap_fail = 0
   o.auditing = conf.auditing
   return setmetatable(o, {__index=esp_v6_decrypt})
end

-- Decapsulation is performed as follows:
--   1. Parse IP and ESP headers and check Sequence Number
--   2. Decrypt ciphertext in place
--   3. Parse ESP trailer and update IP header
--   4. Move cleartext up to IP payload
--   5. Shrink p by ESP overhead
function esp_v6_decrypt:decapsulate (p)
   local gcm = self.aes_128_gcm
   local data, length = p.data, p.length
   if length - PAYLOAD_OFFSET < self.MIN_SIZE then return false end
   self.ip:new_from_mem(data + ETHERNET_SIZE, IPV6_SIZE)
   local payload = data + PAYLOAD_OFFSET
   self.esp:new_from_mem(payload, ESP_SIZE)
   assert(self.ip and self.esp)
   local iv_start = payload + ESP_SIZE
   local ctext_start = payload + self.CTEXT_OFFSET
   local ctext_length = length - self.PLAIN_OVERHEAD
   local seq_low = self.esp:seq_no()
   local seq_high = tonumber(C.check_seq_no(seq_low, self.seq.no, self.window, self.window_size))
   local error = nil
   if seq_high < 0 or not gcm:decrypt(ctext_start, seq_low, seq_high, iv_start, ctext_start, ctext_length) then
      if seq_high < 0 then error = "replayed"
      else                 error = "integrity error" end
      self.decap_fail = self.decap_fail + 1
      if self.decap_fail > self.resync_threshold then
         seq_high = self:resync(p, seq_low, seq_high)
         if seq_high then error = nil end
      end
   end
   if error then
      self:audit(error)
      return false
   else
      self.seq.no = C.track_seq_no(seq_high, seq_low, self.seq.no, self.window, self.window_size)
      local esp_tail_start = ctext_start + ctext_length - ESP_TAIL_SIZE
      self.esp_tail:new_from_mem(esp_tail_start, ESP_TAIL_SIZE)
      assert(self.esp_tail)
      local ptext_length = ctext_length - self.esp_tail:pad_length() - ESP_TAIL_SIZE
      self.ip:next_header(self.esp_tail:next_header())
      self.ip:payload_length(ptext_length)
      C.memmove(payload, ctext_start, ptext_length)
      packet.resize(p, PAYLOAD_OFFSET + ptext_length)
      self.decap_fail = 0
      return true
   end
end

function esp_v6_decrypt:audit (reason)
   if not self.auditing then return end
   -- This is the information RFC4303 says we SHOULD log
   logger:log("Rejecting packet (" ..
              "SPI=" .. self.spi .. ", " ..
              "src_addr='" .. self.ip:ntop(self.ip:src()) .. "', " ..
              "dst_addr='" .. self.ip:ntop(self.ip:dst()) .. "', " ..
              "seq_low=" .. self.esp:seq_no() .. ", " ..
              "flow_id=" .. self.ip:flow_label() .. ", " ..
              "reason='" .. reason .. "'" ..
              ")")
end

function esp_v6_decrypt:resync (p, seq_low, seq_high)
   local gcm = self.aes_128_gcm
   local payload = p.data + PAYLOAD_OFFSET
   local iv_start = payload + ESP_SIZE
   local ctext_start = payload + self.CTEXT_OFFSET
   local ctext_length = p.length - self.PLAIN_OVERHEAD
   if seq_high < 0 then
      -- The sequence number looked replayed, we use the last seq_high we have
      -- seen
      seq_high = self.seq:high()
   else
      -- We failed to decrypt in-place, undo the damage to recover the original
      -- ctext (ignore bogus auth data)
      gcm:encrypt(ctext_start, iv_start, seq_low, seq_high, ctext_start, ctext_length, gcm.auth_buf)
   end
   local p_orig = packet.clone(p)
   for i = 1, self.resync_attempts do
      seq_high = seq_high + 1
      if gcm:decrypt(ctext_start, seq_low, seq_high, iv_start, ctext_start, ctext_length) then
         packet.free(p_orig)
         return seq_high
      else
         ffi.copy(p.data, p_orig.data, p_orig.length)
      end
   end
end

function selftest ()
   local C = require("ffi").C
   local ipv6 = require("lib.protocol.ipv6")
   local conf = { spi = 0x0,
                  mode = "aes-128-gcm",
                  key = "00112233445566778899AABBCCDDEEFF",
                  salt = "00112233",
                  resync_threshold = 16,
                  resync_attempts = 8}
   local enc, dec = esp_v6_encrypt:new(conf), esp_v6_decrypt:new(conf)
   local payload = packet.from_string(
[[abcdefghijklmnopqrstuvwxyz
ABCDEFGHIJKLMNOPQRSTUVWXYZ
0123456789]]
   )
   local d = datagram:new(payload)
   local ip = ipv6:new({})
   ip:payload_length(payload.length)
   d:push(ip)
   d:push(ethernet:new({type=0x86dd}))
   local p = d:packet()
   -- Check integrity
   print("original", lib.hexdump(ffi.string(p.data, p.length)))
   local p_enc = packet.clone(p)
   assert(enc:encapsulate(p_enc), "encapsulation failed")
   print("encrypted", lib.hexdump(ffi.string(p_enc.data, p_enc.length)))
   local p2 = packet.clone(p_enc)
   assert(dec:decapsulate(p2), "decapsulation failed")
   print("decrypted", lib.hexdump(ffi.string(p2.data, p2.length)))
   assert(p2.length == p.length and C.memcmp(p.data, p2.data, p.length) == 0,
          "integrity check failed")
   -- Check invalid packets.
   local p_invalid = packet.from_string("invalid")
   assert(not enc:encapsulate(p_invalid), "encapsulated invalid packet")
   local p_invalid = packet.from_string("invalid")
   assert(not dec:decapsulate(p_invalid), "decapsulated invalid packet")
   -- Check minimum packet.
   local p_min = packet.from_string("012345678901234567890123456789012345678901234567890123")
   p_min.data[18] = 0 -- Set IPv6 payload length to zero
   p_min.data[19] = 0 -- ...
   assert(p_min.length == PAYLOAD_OFFSET)
   print("original", lib.hexdump(ffi.string(p_min.data, p_min.length)))
   local e_min = packet.clone(p_min)
   assert(enc:encapsulate(e_min))
   print("encrypted", lib.hexdump(ffi.string(e_min.data, e_min.length)))
   assert(e_min.length == dec.MIN_SIZE+PAYLOAD_OFFSET)
   assert(dec:decapsulate(e_min))
   print("decrypted", lib.hexdump(ffi.string(e_min.data, e_min.length)))
   assert(e_min.length == PAYLOAD_OFFSET)
   assert(p_min.length == e_min.length
          and C.memcmp(p_min.data, e_min.data, p_min.length) == 0,
          "integrity check failed")
   -- Check transmitted Sequence Number wrap around
   C.memset(dec.window, 0, dec.window_size / 8); -- clear window
   enc.seq.no = 2^32 - 1 -- so next encapsulated will be seq 2^32
   dec.seq.no = 2^32 - 1 -- pretend to have seen 2^32-1
   local px = packet.clone(p)
   enc:encapsulate(px)
   assert(dec:decapsulate(px),
          "Transmitted Sequence Number wrap around failed.")
   assert(dec.seq:high() == 1 and dec.seq:low() == 0,
          "Lost Sequence Number synchronization.")
   -- Check Sequence Number exceeding window
   C.memset(dec.window, 0, dec.window_size / 8); -- clear window
   enc.seq.no = 2^32
   dec.seq.no = 2^32 + dec.window_size + 1
   px = packet.clone(p)
   enc:encapsulate(px)
   assert(not dec:decapsulate(px),
          "Accepted out of window Sequence Number.")
   assert(dec.seq:high() == 1 and dec.seq:low() == dec.window_size+1,
          "Corrupted Sequence Number.")
   -- Test anti-replay: From a set of 15 packets, first send all those
   -- that have an even sequence number.  Then, send all 15.  Verify that
   -- in the 2nd run, packets with even sequence numbers are rejected while
   -- the others are not.
   -- Then do the same thing again, but with offset sequence numbers so that
   -- we have a 32bit wraparound in the middle.
   local offset = 0 -- close to 2^32 in the 2nd iteration
   for offset = 0, 2^32-7, 2^32-7 do -- duh
      C.memset(dec.window, 0, dec.window_size / 8); -- clear window
      dec.seq.no = offset
      for i = 1+offset, 15+offset do
         if (i % 2 == 0) then
            enc.seq.no = i-1 -- so next seq will be i
            px = packet.clone(p)
            enc:encapsulate(px);
            assert(dec:decapsulate(px), "rejected legitimate packet seq=" .. i)
            assert(dec.seq.no == i, "Lost sequence number synchronization")
         end
      end
      for i = 1+offset, 15+offset do
         enc.seq.no = i-1
         px = packet.clone(p)
         enc:encapsulate(px);
         if (i % 2 == 0) then
            assert(not dec:decapsulate(px), "accepted replayed packet seq=" .. i)
         else
            assert(dec:decapsulate(px), "rejected legitimate packet seq=" .. i)
         end
      end
   end
   -- Check that packets from way in the past/way in the future
   -- (further than the biggest allowable window size) are rejected
   -- This is where we ultimately want resynchronization (wrt. future packets)
   C.memset(dec.window, 0, dec.window_size / 8); -- clear window
   dec.seq.no = 2^34 + 42;
   enc.seq.no = 2^36 + 24;
   px = packet.clone(p)
   enc:encapsulate(px);
   assert(not dec:decapsulate(px), "accepted packet from way into the future")
   enc.seq.no = 2^32 + 42;
   px = packet.clone(p)
   enc:encapsulate(px);
   assert(not dec:decapsulate(px), "accepted packet from way into the past")
   -- Test resynchronization after having lost  >2^32 packets
   enc.seq.no = 0
   dec.seq.no = 0
   C.memset(dec.window, 0, dec.window_size / 8); -- clear window
   px = packet.clone(p) -- do an initial packet
   enc:encapsulate(px)
   assert(dec:decapsulate(px), "decapsulation failed")
   enc.seq:high(3) -- pretend there has been massive packet loss
   enc.seq:low(24)
   for i = 1, dec.resync_threshold do
      px = packet.clone(p)
      enc:encapsulate(px)
      assert(not dec:decapsulate(px), "decapsulated pre-resync packet")
   end
   px = packet.clone(p)
   enc:encapsulate(px)
   assert(dec:decapsulate(px), "failed to resynchronize")
   -- Make sure we don't accidentally resynchronize with very old replayed
   -- traffic
   enc.seq.no = 42
   for i = 1, dec.resync_threshold do
      px = packet.clone(p)
      enc:encapsulate(px)
      assert(not dec:decapsulate(px), "decapsulated very old packet")
   end
   px = packet.clone(p)
   enc:encapsulate(px)
   assert(not dec:decapsulate(px), "resynchronized with the past!")
end
