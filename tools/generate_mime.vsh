#!/usr/bin/env -S v -gc none run

import crypto.sha256
import os
import strings

// The hash constants and window layout must match src/mime/mime.v.
const mix_last = u64(0x8BB84B93962EACC9)
const mix_middle = u64(0x4B33A62ED433D4A3)
const mix_length = u64(0x9E3779B97F4A7C15)
const multipliers = [u64(0x2D358DCCAA6C78A5), 0xBF58476D1CE4E5B9, 0x94D049BB133111EB,
	0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9, 0x27D4EB2F165667C5, 0x853C49E6748FEA9B, 0x53D3C1AE0BE2E1F5,
	0x2545F4914F6CDD1D, 0x9FB42AB9E0E0F6A1, 0x5E4FDBBA6A5C6A37, 0x7BD8F89031AF0A6D]!

struct MimeEntry {
	extension  string
	media_type string
}

struct PerfectHash {
	multiplier    u64
	shift         int
	bucket_mask   u32
	table_mask    u32
	displacements []u16
	slots         []int
}

fn read_entries(source string) ![]MimeEntry {
	marker := 'const ext_to_mt_str = {'
	if !source.contains(marker) { return error('extension mapping not found in source database') }
	table := source.all_after(marker).trim_space()
	if !table.ends_with('}') { return error('invalid extension mapping') }
	mut entries := []MimeEntry{}
	for raw in table[..table.len - 1].split_into_lines() {
		line := raw.trim_space()
		if line == '' { continue }
		parts := line.split("'")
		if parts.len != 5 || parts[0] != '' || parts[2].trim_space() != ':' || parts[4] != '' || parts[1] == '' || parts[3] == '' || parts[1].contains('\\') || parts[3].contains('\\') {
			return error('unexpected extension entry: ${line}')
		}
		if parts[1].len > 24 {
			return error('extension exceeds the 24-byte hash window: ${parts[1]}')
		}
		entries << MimeEntry{parts[1], parts[3]}
	}
	if entries.len == 0 { return error('empty extension mapping') }
	entries.sort(a.extension < b.extension)
	for i in 1 .. entries.len {
		if entries[i - 1].extension == entries[i].extension {
			return error('duplicate extension: ${entries[i].extension}')
		}
	}
	return entries
}

fn word(s string, start int, length int) u64 {
	mut result := u64(0)
	mut place := u64(1)
	for i in start .. start + length {
		result += u64(s[i]) * place
		place <<= 8
	}
	return result
}

fn extension_hash(ext string, multiplier u64) u32 {
	first := word(ext, 0, if ext.len < 8 { ext.len } else { 8 })
	last := if ext.len > 8 { word(ext, ext.len - 8, 8) } else { u64(0) }
	middle := if ext.len > 16 { word(ext, 8, 8) } else { u64(0) }
	x := (first * multiplier) ^ (last * mix_last) ^ (middle * mix_middle) ^ (u64(ext.len) * mix_length)
	return u32(x ^ (x >> 32))
}

fn place_bucket(bucket []int, hashes []u32, shift int, mask u32, mut slots []int) ?u16 {
	for displacement in 0 .. slots.len {
		mut targets := []int{cap: bucket.len}
		for index in bucket {
			target := int(((hashes[index] >> shift) + u32(displacement)) & mask)
			if slots[target] != -1 || target in targets { break }
			targets << target
		}
		if targets.len != bucket.len { continue }
		for i, target in targets { slots[target] = bucket[i] }
		return u16(displacement)
	}
	return none
}

// Build the CHD table largest buckets first, with deterministic tie breaking.
fn perfect_hash(entries []MimeEntry) !PerfectHash {
	mut size := 2048
	for entries.len * 4 > size * 3 { size *= 2 }
	if size > 65536 { return error('too many extensions for u16 displacements') }
	buckets_len := size / 4
	mut shift := 0
	for (1 << shift) < buckets_len { shift++ }
	for multiplier in multipliers {
		hashes := entries.map(extension_hash(it.extension, multiplier))
		mut seen := map[u32]bool{}
		mut buckets := [][]int{len: buckets_len}
		for i, hash in hashes {
			key := hash & ((u32(size) << shift) - 1)
			if key in seen { break }
			seen[key] = true
			buckets[hash & u32(buckets_len - 1)] << i
		}
		if seen.len != entries.len { continue }
		mut largest := 0
		for bucket in buckets { if bucket.len > largest { largest = bucket.len } }
		mut slots := []int{len: size, init: -1}
		mut displacements := []u16{len: buckets_len}
		mut complete := true
		for length := largest; length > 0 && complete; length-- {
			for i, bucket in buckets {
				if bucket.len != length { continue }
				displacements[i] = place_bucket(bucket, hashes, shift, u32(size - 1), mut slots) or {
					complete = false
					break
				}
			}
		}
		if complete {
			return PerfectHash{multiplier, shift, u32(buckets_len - 1), u32(size - 1), displacements, slots}
		}
	}
	return error('no perfect hash found for ${entries.len} extensions')
}

fn literal(value string) string {
	mut result := strings.new_builder(value.len + 2)
	result.write_u8(`'`)
	for b in value {
		if b >= 32 && b < 127 && b !in [u8(`'`), `\\`, `$`] {
			result.write_u8(b)
		} else {
			result.write_string('\\x${b:02x}')
		}
	}
	result.write_u8(`'`)
	return result.str()
}

fn emit_array(mut output strings.Builder, name string, kind string, values []string) {
	output.writeln('const ${name} = [')
	for i, value in values {
		if i % 8 == 0 { output.write_string('\t') }
		output.write_string(if i == 0 && kind != '' { '${kind}(${value})' } else { value })
		if (i + 1) % 8 == 0 || i + 1 == values.len {
			output.writeln(',')
		} else {
			output.write_string(', ')
		}
	}
	output.writeln(']!\n')
}

fn generate() ! {
	if os.args.len != 2 {
		return error('Usage: v -gc none run tools/generate_mime.vsh path/to/vlib/net/http/mime/db.v')
	}
	source := os.read_file(os.args[1])!
	entries := read_entries(source)!
	table := perfect_hash(entries)!
	mut names_set := map[string]bool{}
	for entry in entries { names_set[entry.media_type] = true }
	mut names := names_set.keys()
	names.sort()
	names.prepend('')
	mut name_index := map[string]int{}
	for i, name in names { name_index[name] = i }
	mut bits := 1
	for names.len > (1 << bits) { bits++ }
	mut blob := []u8{len: 8}
	mut offsets := []int{cap: entries.len}
	for entry in entries {
		offsets << blob.len - 8
		blob << u8(entry.extension.len)
		blob << entry.extension.bytes()
	}
	blob << []u8{len: 16}
	if bits + 5 >= 32 || u64(blob.len) >= (u64(1) << (32 - bits - 5)) {
		return error('extension table exceeds packed slot size')
	}
	mut packed := []u32{len: table.slots.len}
	for slot, index in table.slots {
		if index == -1 { continue }
		entry := entries[index]
		packed[slot] = (u32(offsets[index] + 1) << (bits + 5)) | (u32(entry.extension.len) << bits) | u32(name_index[entry.media_type])
	}
	// Verify every source mapping against its generated slot before writing anything.
	for entry in entries {
		hash := extension_hash(entry.extension, table.multiplier)
		slot := packed[((hash >> table.shift) + table.displacements[hash & table.bucket_mask]) & table.table_mask]
		length := int((slot >> bits) & 31)
		start := int(slot >> (bits + 5)) + 8
		if blob[start..start + length].bytestr() != entry.extension || names[slot & u32((1 << bits) - 1)] != entry.media_type {
			return error('perfect hash self-check failed: ${entry.extension}')
		}
	}
	mut output := strings.new_builder(64 * 1024)
	output.write_string("module mime\n\n// Generated by tools/generate_mime.vsh from V's vlib/net/http/mime/db.v.\n// Source SHA-256: ${sha256.hexhash(source)}\n// See doc/THIRD_PARTY.md for attribution. Do not edit by hand.\n// CHD perfect hash: ${entries.len} extensions, no runtime table construction.\n")
	output.writeln('const ph_m1 = u64(0x${table.multiplier.hex()})')
	output.writeln('const ph_slot_shift = ${table.shift}')
	output.writeln('const ph_bmask = u32(${table.bucket_mask})')
	output.writeln('const ph_tmask = u32(${table.table_mask})')
	output.writeln('const ph_mbits = ${bits}\n')
	emit_array(mut output, 'ph_disp', 'u16', table.displacements.map(it.str()))
	emit_array(mut output, 'ph_slots', 'u32', packed.map(it.str()))
	output.writeln('// Eight leading and sixteen trailing padding bytes make stored word reads safe.')
	output.writeln('const ph_blob = ${literal(blob.bytestr())}\n')
	emit_array(mut output, 'mime_names', '', names.map(literal(it)))
	output.go_back(1)
	os.write_file(os.join_path(@VMODROOT, 'src', 'mime', 'data.v'), output.str())!
	println('Generated and verified ${entries.len} MIME mappings in ${packed.len} perfect-hash slots')
}

fn main() {
	generate() or {
		eprintln(err)
		exit(1)
	}
}
