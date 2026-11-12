module main

const vaddy_version = '0.1.0'

fn main() {
	cli() or {
		eprintln('vaddy: ${err}')
		exit(1)
	}
}
