module mime

// Keep the word layout and mix constants in sync with tools/generate_mime.vsh.
const ph_m2 = u64(0x8BB84B93962EACC9)
const ph_m3 = u64(0x4B33A62ED433D4A3)
const ph_m4 = u64(0x9E3779B97F4A7C15)
const ph_max_ext_len = 24
const ph_masks = [u64(0), 0xFF, 0xFFFF, 0xFFFFFF, 0xFFFFFFFF, 0xFFFFFFFFFF, 0xFFFFFFFFFFFF,
	0xFFFFFFFFFFFFFF, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64,
	max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64, max_u64]!

// Check the full window once before assembling the unaligned little-endian word.
@[direct_array_access; inline]
fn word(s string, start int) u64 {
	if start < 0 || start > s.len - 8 { return 0 }
	return u64(s[start]) | (u64(s[start + 1]) << 8) | (u64(s[start + 2]) << 16) |
		(u64(s[start + 3]) << 24) | (u64(s[start + 4]) << 32) | (u64(s[start + 5]) << 40) |
		(u64(s[start + 6]) << 48) | (u64(s[start + 7]) << 56)
}

// lookup returns the media type for an exact lowercase extension, or '' if unknown.
// Its perfect hash and full-key check use static tables without allocating.
// Length checks and hash masks bound the indexes into the generated tables.
@[direct_array_access; inline]
pub fn lookup(ext string) string {
	length := ext.len
	if length == 0 || length > ph_max_ext_len { return '' }
	mut first := u64(0)
	mut last := u64(0)
	mut middle := u64(0)
	if length >= 8 {
		// Every input word is entirely inside ext.
		first = word(ext, 0)
		if length > 8 { last = word(ext, length - 8) }
		if length > 16 { middle = word(ext, 8) }
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
	if stored_length != length { return '' }
	// The generated blob pads the final key so short keys have a full first word.
	start := int(slot >> (ph_mbits + 5)) + 8
	mask := ph_masks[length]
	if (first & mask) != (word(ph_blob, start) & mask) { return '' }
	if length > 8 && last != word(ph_blob, start + length - 8) { return '' }
	if length > 16 && middle != word(ph_blob, start + 8) { return '' }
	return mime_names[slot & ((u32(1) << ph_mbits) - 1)]
}
