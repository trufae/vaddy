module main

import net.http

fn parse_redirect(d Directive) !Route {
	if d.children.len > 0 || d.args.len < 2 || d.args.len > 4 { return error('expected redir [matcher] target [code]') }
	mut args := d.args[1..].clone()
	mut route := Route{}
	// Optional matcher extraction precedes redir's target/code arguments.
	if args[0].starts_with('@') || args[0].starts_with('/') || args[0] == '*' {
		if args[0].starts_with('@') { route.matcher = args[0] }
		else if args[0] != '*' { route.patterns = [args[0]] }
		args.delete(0)
	}
	if args.len !in [1, 2] { return error('invalid redirect arguments') }
	route.redirect = args[0]
	if args.len == 2 {
		code := args[1]
		match code {
			'permanent' { route.redirect_code = 301 }
			'temporary' { route.redirect_code = 302 }
			'html' { route.redirect_code = 200; route.redirect_html = true }
			else {
				if code.starts_with('{') { route.redirect_status = code }
				else {
					if code.len != 3 || !all_digits(code) || (code.int() !in 300 .. 400 && code != '401') {
						return error('redirect code must be 3xx, 401, permanent, temporary, html or a placeholder')
					}
					route.redirect_code = code.int()
				}
			}
		}
	}
	if route.redirect == '' || route.redirect.len > header_limit / 2 || invalid_controls(route.redirect, false) {
		return error('invalid redirect target')
	}
	return route
}

fn redirect_reason(code int) string {
	return http.status_from_int(code).str()
}

fn html_redirect(target string) string {
	// Match Caddy's static-response HTML template and configuration-time escaping.
	safe := target.replace('&', '&amp;').replace("'", '&#39;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&#34;')
	return '<!DOCTYPE html>\n<html>\n\t<head>\n\t\t<title>Redirecting...</title>\n\t\t<script>window.location.replace("${safe}");</script>\n\t\t<meta http-equiv="refresh" content="0; URL=\'${safe}\'">\n\t</head>\n\t<body>Redirecting to <a href="${safe}">${safe}</a>...</body>\n</html>\n'
}

fn (mut s Server) redirect_response(mut c Connection, route Route) ! {
	mut code := route.redirect_code
	if route.redirect_status != '' {
		status := expand_header(route.redirect_status, c.header_values)!
		if status.len != 3 || !all_digits(status) || status.int() < 200 || status.int() > 599 {
			s.respond(mut c, 500, 'Internal Server Error', '', '')
			return
		}
		code = status.int()
	}
	body := if route.redirect_html { expand_placeholders(html_redirect(route.redirect), c.header_values)! } else { '' }
	location := expand_header(route.redirect, c.header_values)!
	if invalid_controls(location, false) { return error('invalid redirect target') }
	extra := if route.redirect_html { '' } else { 'Location: ${location}\r\n' }
	s.respond_options(mut c, code, redirect_reason(code), body, extra, true,
		if route.redirect_html { 'text/html; charset=utf-8' } else { '' })
}
