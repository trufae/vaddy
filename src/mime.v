module main

struct MimeEntry {
	extension string
	media_type string
}

// The sorted, immutable extension table is shared by all workers. Unknown
// extensions retain the previous empty type, without content sniffing.
fn file_mime_type(extension string) string {
	mut low := 0
	mut high := mime_extensions.len
	for low < high {
		mid := low + (high - low) / 2
		entry := mime_extensions[mid]
		if extension == entry.extension { return entry.media_type }
		if extension < entry.extension { high = mid } else { low = mid + 1 }
	}
	return ''
}
