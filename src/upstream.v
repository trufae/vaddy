module main

import net.urllib

struct Backend {
	address voidptr
	ctx     voidptr
	name    string
}

// Prepared before serving requests; workers only read this table.
fn prepare_backends(cfg Config) !map[string]Backend {
	mut backends := map[string]Backend{}
	mut complete := false
	defer { if !complete { free_backends(backends) } }
	for site in cfg.sites {
		for route in site.routes {
			key := route.backend_key()
			if route.upstream == '' || key in backends { continue }
			tls := route.upstream.starts_with('https://')
			u := urllib.parse(if tls { route.upstream } else { 'http://${route.upstream}' })!
			address := C.vaddy_resolve(&char(u.hostname().str), &char(u.port().str))
			if address == unsafe { nil } { return error('cannot resolve upstream ${route.upstream}') }
			mut ctx := voidptr(0)
			if tls {
				ctx = C.vaddy_upstream_context(&char(route.tls_ca.str))
				if ctx == unsafe { nil } {
					unsafe { free(address) }
					return error('cannot load upstream trust roots for ${route.upstream}')
				}
			}
			backends[key] = Backend{address, ctx, if route.tls_server_name == '' { u.hostname() } else { route.tls_server_name }}
		}
	}
	complete = true
	return backends
}

fn free_backends(backends map[string]Backend) {
	for _, backend in backends {
		unsafe { free(backend.address) }
		if backend.ctx != unsafe { nil } { C.vaddy_tls_ctx_free(backend.ctx) }
	}
}
