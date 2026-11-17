module regex

fn test_regex_substitutions_and_bounded_output() ! {
	assert replace('(a)(b)', r'$2-${1}-$$-$0', 'ab ab', 16384)! == 'b-a-$-ab b-a-$-ab'
	assert replace('(?P<word>ab)', r'${word}:$word', 'ab', 16384)! == 'ab:ab'
	assert replace('(a)', r'$1suffix-${1}suffix', 'a', 16384)! == '-asuffix'
	assert replace('', '-', 'é猫', 16384)! == '-é-猫-'
	assert replace('a*', '-', 'aaab', 16384)! == '-b-'
	if _ := replace('x', 'y'.repeat(16384), 'xx', 16384) { assert false }
	if _ := replace('(?<=a)b', 'x', 'ab', 16384) { assert false }
}
