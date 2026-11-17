module mime

fn test_file_mime_types() {
	assert lookup('html') == 'text/html'
	assert lookup('css') == 'text/css'
	assert lookup('json') == 'application/json'
	assert lookup('svg') == 'image/svg+xml'
	assert lookup('wasm') == 'application/wasm'
	assert lookup('docx') == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
	assert lookup('hsj2') == 'image/hsj2'
	assert lookup('aif') == 'audio/x-aiff'
	assert lookup('aiff') == 'audio/x-aiff'
	assert lookup('tif') == 'image/tiff'
	assert lookup('tiff') == 'image/tiff'
	assert lookup('v') == 'text/x-vlang'
	assert lookup('vsh') == 'text/x-vlang'
	assert lookup('disposition-notification') == 'message/disposition-notification'
	for extension in ['', '.', 'HTML', '.html', 'unknown-extension', ' html', 'html\x00txt', 'j\xd3on',
		'vbox-extpacx', 'x'.repeat(25)] {
		assert lookup(extension) == ''
	}
}

fn test_every_generated_extension_and_non_ascii_misses() {
	assert mime_names[0] == ''
	mut seen := map[string]bool{}
	for slot in ph_slots {
		if slot == 0 { continue }
		length := int((slot >> ph_mbits) & 31)
		start := int(slot >> (ph_mbits + 5)) + 8
		extension := ph_blob[start..start + length]
		assert extension !in seen
		seen[extension] = true
		assert lookup(extension) == mime_names[slot & ((u32(1) << ph_mbits) - 1)]
		assert lookup(extension + '\x00') == ''
		for i in 0 .. extension.len {
			mut bytes := extension.bytes()
			bytes[i] |= 0x80
			assert lookup(bytes.bytestr()) == ''
		}
	}
	assert seen.len == 1203
}

fn test_long_misses_probe_padded_short_keys_safely() {
	for length in 8 .. 25 {
		for i in 0 .. 256 {
			assert lookup('z'.repeat(length - 4) + '${i:04}') == ''
		}
	}
}
