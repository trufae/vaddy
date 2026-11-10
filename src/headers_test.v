module main

fn test_regex_substitutions_and_bounded_output() ! {
	assert regex_replace('(a)(b)', r'$2-${1}-$$-$0', 'ab ab')! == 'b-a-$-ab b-a-$-ab'
	assert regex_replace('(?P<word>ab)', r'${word}:$word', 'ab')! == 'ab:ab'
	assert regex_replace('(a)', r'$1suffix-${1}suffix', 'a')! == '-asuffix'
	assert regex_replace('', '-', 'é猫')! == '-é-猫-'
	assert regex_replace('a*', '-', 'aaab')! == '-b-'
	if _ := regex_replace('x', 'y'.repeat(header_limit), 'xx') { assert false }
	if _ := regex_replace('(?<=a)b', 'x', 'ab') { assert false }
}
