module mime

// Keep the word layout and mix constants in sync with tools/generate_mime.vsh.
const ph_m2 = u64(0x8BB84B93962EACC9)
const ph_m3 = u64(0x4B33A62ED433D4A3)
const ph_m4 = u64(0x9E3779B97F4A7C15)
const ph_max_ext_len = 24
const ph_masks = [u64(0), 0xFF, 0xFFFF, 0xFFFFFF, 0xFFFFFFFF, 0xFFFFFFFFFF, 0xFFFFFFFFFFFF,
	0xFFFFFFFFFFFFFF, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64,
	max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64]!

// Byte assembly supports unaligned input and either host byte order.
@[direct_array_access; inline; unsafe]
fn word(p &u8) u64 {
	return unsafe {
		u64(p[0]) | (u64(p[1]) << 8) | (u64(p[2]) << 16) | (u64(p[3]) << 24) |
			(u64(p[4]) << 32) | (u64(p[5]) << 40) | (u64(p[6]) << 48) | (u64(p[7]) << 56)
	}
}

// lookup returns the media type for an exact lowercase extension, or '' if unknown.
// Its perfect hash and full-key check use static tables without allocating.
@[direct_array_access; inline]
pub fn lookup(ext string) string {
	length := ext.len
	if length == 0 || length > ph_max_ext_len { return '' }
	mut first := u64(0)
	mut last := u64(0)
	mut middle := u64(0)
	if length >= 8 {
		// Every input word is entirely inside ext.
		first = unsafe { word(ext.str) }
		if length > 8 { last = unsafe { word(ext.str + length - 8) } }
		if length > 16 { middle = unsafe { word(ext.str + 8) } }
	} else {
		mut place := u64(1)
		for i in 0 .. length {
			first += u64(ext[i]) * place
			place <<= 8
		}
	}
	x := (first * ph_m1) ^ (last * ph_m2) ^ (middle * ph_m3) ^ (u64(length) * ph_m4)
	hash := u32(x ^ (x >> 32))
	slot := ph_slots[((hash >> ph_slot_shift) + ph_disp[hash & ph_bmask]) & ph_tmask]
	stored_length := int((slot >> ph_mbits) & 31)
	// Padding covers all three reads even for an empty slot or a shorter stored key.
	p := unsafe { ph_blob.str + int(slot >> (ph_mbits + 5)) + 8 }
	mask := ph_masks[length]
	mut equal := u64(stored_length == length)
	equal &= u64((first & mask) == (unsafe { word(p) } & mask))
	if length > 8 { equal &= u64(last == unsafe { word(p + stored_length - 8) }) }
	if length > 16 { equal &= u64(middle == unsafe { word(p + 8) }) }
	index := if equal != 0 { slot & ((u32(1) << ph_mbits) - 1) } else { u32(0) }
	return mime_names[index]
}
