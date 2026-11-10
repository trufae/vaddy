module main

fn parse_redirect(d Directive) !Route {
	if d.children.len > 0 || d.args.len < 2 || d.args.len > 4 { return error('expected redir [matcher] target [code]') }
	mut args := d.args[1..].clone()
	mut route := Route{}
	if args.len > 1 {
		last := args.last()
		if last in ['permanent', 'temporary'] || all_digits(last) {
			if last !in ['permanent', 'temporary', '301', '302', '303', '307', '308'] { return error('unsupported redirect code') }
			route.redirect_code = match last {
				'permanent' { 301 }
				'temporary' { 302 }
				else { last.int() }
			}
			if route.redirect_code !in [301, 302, 303, 307, 308] { return error('redirect code must be 301, 302, 303, 307 or 308') }
			args.delete_last()
		}
	}
	if args.len == 2 {
		matcher := args[0]
		if matcher.starts_with('@') { route.matcher = matcher }
		else if matcher.starts_with('/') || matcher == '*' { route.patterns = [matcher] }
		else { return error('unsupported redirect matcher') }
	} else if args.len != 1 { return error('invalid redirect arguments') }
	route.redirect = args.last()
	if route.redirect == '' || route.redirect.len > header_limit / 2 || invalid_controls(route.redirect, false) || route.redirect.contains(' ') || !supported_placeholders(route.redirect) {
		return error('invalid redirect target or placeholder')
	}
	return route
}

fn redirect_reason(code int) string {
	return match code {
		301 { 'Moved Permanently' }
		302 { 'Found' }
		303 { 'See Other' }
		307 { 'Temporary Redirect' }
		else { 'Permanent Redirect' }
	}
}
