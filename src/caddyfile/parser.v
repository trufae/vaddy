module caddyfile

pub struct Directive {
pub:
	args     []string
	children []Directive
	line     int
}

struct Token {
	text string
	line int
}

fn tokenize(input string) ![]Token {
	mut tokens := []Token{}
	mut i := 0
	mut line := 1
	for i < input.len {
		c := input[i]
		if c == `\n` {
			tokens << Token{'\n', line}
			line++
			i++
			continue
		}
		if c in [u8(` `), `\t`, `\r`] {
			i++
			continue
		}
		if c == `#` {
			for i < input.len && input[i] != `\n` { i++ }
			continue
		}
		start := i
		if c == `"` {
			i++
			mut value := []u8{}
			for i < input.len && input[i] != `"` {
				if input[i] == `\n` { return error('line ${line}: newline in quoted token') }
				if input[i] == `\\` && i + 1 < input.len && input[i + 1] == `"` { i++ }
				value << input[i]
				i++
			}
			if i == input.len { return error('line ${line}: unterminated quote') }
			i++
			tokens << Token{value.bytestr(), line}
		} else {
			for i < input.len && input[i] !in [u8(` `), `\t`, `\r`, `\n`] { i++ }
			tokens << Token{input[start..i], line}
		}
	}
	return tokens
}

struct Cursor {
mut:
	pos int
}

fn parse_nodes(tokens []Token, mut cursor Cursor, nested bool) ![]Directive {
	mut nodes := []Directive{}
	for cursor.pos < tokens.len {
		if tokens[cursor.pos].text == '\n' {
			cursor.pos++
			continue
		}
		if tokens[cursor.pos].text == '}' {
			if !nested { return error('line ${tokens[cursor.pos].line}: unexpected }') }
			cursor.pos++
			return nodes
		}
		line := tokens[cursor.pos].line
		mut args := []string{}
		for cursor.pos < tokens.len && tokens[cursor.pos].text !in ['\n', '{', '}'] {
			args << tokens[cursor.pos].text
			cursor.pos++
		}
		mut children := []Directive{}
		if cursor.pos < tokens.len && tokens[cursor.pos].text == '{' {
			cursor.pos++
			children = parse_nodes(tokens, mut cursor, true)!
		} else if args.len == 0 {
			return error('line ${line}: expected directive')
		}
		nodes << Directive{args, children, line}
	}
	if nested { return error('missing closing }') }
	return nodes
}

pub fn parse(input string) ![]Directive {
	mut cursor := Cursor{}
	return parse_nodes(tokenize(input)!, mut cursor, false)
}
