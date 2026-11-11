module main

import os
import time
import x.json2
import crypto.sha256
import crypto.rand as crypto_rand
import encoding.base64
import encoding.hex
import net.http
import net.urllib

type AcmeTransport = fn (http.Method, string, string) !http.Response

struct AcmeDirectory {
	new_nonce   string @[json: 'newNonce']
	new_account string @[json: 'newAccount']
	new_order   string @[json: 'newOrder']
}

struct Identifier {
	type_ string = 'dns' @[json: 'type']
	value string
}

struct NewOrder {
	identifiers []Identifier
}

struct NewAccount {
	terms_of_service_agreed bool = true @[json: 'termsOfServiceAgreed']
	contact                 []string    @[omitempty]
}

struct AcmeOrder {
	status         string
	authorizations []string
	finalize       string
	certificate    string
}

struct Challenge {
	type_ string @[json: 'type']
	url   string
	token string
}

struct Authorization {
	status     string
	identifier Identifier
	challenges []Challenge
}

struct AcmeProblem {
	type_  string @[json: 'type']
	detail string
}

struct Jws {
	protected string
	payload   string
	signature string
}

struct Finalize {
	csr string
}

struct AcmeClient {
mut:
	transport   AcmeTransport = acme_http
	directory   AcmeDirectory
	nonce       string
	kid         string
	jwk         string
	thumbprint  string
	account_dir string
	openssl     string
}

fn openssl_command(exe string, args []string) !string {
	mut p := os.new_process(exe)
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	// Drain both pipes concurrently so verbose OpenSSL errors cannot block it.
	stderr_reader := spawn p.stderr_slurp()
	output := p.stdout_slurp() + stderr_reader.wait()
	p.wait()
	code := p.code
	p.close()
	if code != 0 { return error('openssl ${args[0]} failed (${code}): ${output.trim_space()}') }
	return output.trim_space()
}

fn atomic_write(path string, data string) ! {
	tmp := path + '.tmp'
	os.write_file(tmp, data)!
	os.chmod(tmp, 0o600)!
	if C.vaddy_replace(&char(tmp.str), &char(path.str)) != 0 { return error('cannot publish ${path}') }
}

fn safe_generation(s string) bool {
	return s.starts_with('cert-') && s.len < 100 && s.bytes().all(it.is_alnum() || it == `-`)
}

fn acme_url(url string) ! {
	u := urllib.parse(url)!
	if u.scheme != 'https' && !(u.scheme == 'http' && u.hostname() in ['localhost', '127.0.0.1',
		'::1']) {
		return error('ACME endpoints must use HTTPS (HTTP is allowed only on loopback for testing)')
	}
	if u.host == '' || url.contains('@') || u.fragment != '' {
		return error('invalid ACME endpoint')
	}
}

fn acme_http(method http.Method, url string, data string) !http.Response {
	acme_url(url)!
	mut req := http.Request{
		method:               method
		url:                  url
		data:                 data
		header:               http.new_header(key: .content_type, value: 'application/jose+json')
		allow_redirect:       false
		validate:             true
		max_retries:          1
		read_timeout:         30 * time.second
		write_timeout:        30 * time.second
		stop_receiving_limit: 1024 * 1024
	}
	return req.do()
}

fn response_ok(resp http.Response) ! {
	if resp.status_code < 200 || resp.status_code >= 300 {
		problem := json2.decode[AcmeProblem](resp.body) or {
			AcmeProblem{
				detail: resp.body[..if resp.body.len < 500 {
					resp.body.len
				} else {
					500
				}]
			}
		}
		return error('ACME HTTP ${resp.status_code}: ${problem.type_} ${problem.detail}')
	}
}

fn (mut a AcmeClient) post(url string, payload string, use_jwk bool) !http.Response {
	for _ in 0 .. 3 {
		if a.nonce == '' {
			r := a.transport(http.Method.head, a.directory.new_nonce, '')!
			response_ok(r)!
			a.nonce = r.header.get_custom('Replay-Nonce') or { return error('ACME nonce missing') }
		}
		identity := if use_jwk {
			'"jwk":${a.jwk}'
		} else {
			'"kid":${json2.encode(a.kid, escape_unicode: true)}'
		}
		protected := base64.url_encode_str('{"alg":"RS256","nonce":${json2.encode(a.nonce,
			escape_unicode: true
		)},"url":${json2.encode(url, escape_unicode: true)},${identity}}')
		encoded := base64.url_encode_str(payload)
		input := os.join_path(a.account_dir, 'sign.input')
		output := os.join_path(a.account_dir, 'sign.output')
		os.write_file(input, '${protected}.${encoded}')!
		openssl_command(a.openssl, ['dgst', '-sha256', '-sign',
			os.join_path(a.account_dir, 'account.key'), '-out', output, input])!
		signature := base64.url_encode(os.read_bytes(output)!)
		a.nonce = '' // A nonce is never reused, including after a transport failure.
		resp := a.transport(http.Method.post, url, json2.encode(Jws{protected, encoded, signature},
			escape_unicode: true
		))!
		a.nonce = resp.header.get_custom('Replay-Nonce') or { '' }
		if resp.status_code == 400 {
			problem := json2.decode[AcmeProblem](resp.body) or { AcmeProblem{} }
			if problem.type_.ends_with(':badNonce') { continue }
		}
		response_ok(resp)!
		return resp
	}
	return error('ACME repeatedly rejected fresh nonces')
}

fn new_acme(cfg Config, opts Options, exe string) !AcmeClient {
	account_dir := os.join_path(opts.data, 'accounts', sha256.hexhash(cfg.acme_ca)[..16])
	os.mkdir_all(account_dir, mode: 0o700)!
	key := os.join_path(account_dir, 'account.key')
	if !os.exists(key) {
		openssl_command(exe, ['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
			'-pkeyopt', 'rsa_keygen_pubexp:65537', '-out', key + '.tmp'])!
		os.rename(key + '.tmp', key)!
	}
	modulus := openssl_command(exe, ['rsa', '-in', key, '-modulus', '-noout'])!
	n := base64.url_encode(hex.decode(modulus.all_after('Modulus='))!)
	jwk := '{"e":"AQAB","kty":"RSA","n":"${n}"}'
	resp := opts.acme_transport(http.Method.get, cfg.acme_ca, '')!
	response_ok(resp)!
	directory := json2.decode[AcmeDirectory](resp.body)!
	acme_url(directory.new_nonce)!
	acme_url(directory.new_account)!
	acme_url(directory.new_order)!
	mut a := AcmeClient{ transport: opts.acme_transport, directory: directory, jwk: jwk, thumbprint: base64.url_encode(sha256.sum(jwk.bytes())), account_dir: account_dir, openssl: exe }
	// newAccount is idempotent for the persisted key; also recovers after a crash before saving the account URL.
	contact := if cfg.email == '' { []string{} } else { ['mailto:${cfg.email}'] }
	account := a.post(directory.new_account, json2.encode(NewAccount{ contact: contact },
		escape_unicode: true
	), true)!
	a.kid = account.header.get_custom('Location') or { return error('ACME account Location missing') }
	atomic_write(os.join_path(account_dir, 'account.url'), a.kid)!
	return a
}

fn retry_pause(resp http.Response) {
	value := resp.header.get_custom('Retry-After') or { '2' }
	mut delay := value.int()
	if delay < 1 { delay = 2 }
	if delay > 30 { delay = 30 }
	for _ in 0 .. delay {
		if C.vaddy_stopped() != 0 { return }
		time.sleep(time.second)
	}
}

fn (mut a AcmeClient) authorize(url string, cfg Config, opts Options) ! {
	r := a.post(url, '', false)!
	auth := json2.decode[Authorization](r.body)!
	if auth.identifier.type_ != 'dns' || auth.identifier.value !in cfg.domains() {
		return error('ACME returned an unexpected authorization identifier')
	}
	if auth.status == 'valid' { return }
	if auth.status != 'pending' { return error('ACME authorization status ${auth.status}') }
	for ch in auth.challenges {
		if ch.type_ != 'http-01' { continue }
		if ch.token.len < 16 || ch.token.len > 256 || !ch.token.bytes().all(it.is_alnum() || it in [
			u8(`-`),
			`_`,
		]) {
			return error('invalid ACME challenge token')
		}
		path := os.join_path(opts.data, 'challenges', ch.token)
		atomic_write(path, '${ch.token}.${a.thumbprint}')!
		defer { os.rm(path) or {} }
		a.post(ch.url, '{}', false)!
		for _ in 0 .. 90 {
			if C.vaddy_stopped() != 0 { return error('shutdown') }
			resp := a.post(url, '', false)!
			state := json2.decode[Authorization](resp.body)!
			if state.status == 'valid' { return }
			if state.status !in ['pending', 'processing'] {
				return error('ACME HTTP-01 failed for ${auth.identifier.value}: ${resp.body}')
			}
			retry_pause(resp)
		}
		return error('ACME authorization timed out')
	}
	return error('CA did not offer HTTP-01')
}

fn issue_acme(cfg Config, opts Options, exe string, dir string) ! {
	mut a := new_acme(cfg, opts, exe)!
	ids := cfg.domains().map(Identifier{ value: it })
	r := a.post(a.directory.new_order, json2.encode(NewOrder{ids},
		escape_unicode: true
	), false)!
	mut order := json2.decode[AcmeOrder](r.body)!
	order_url := r.header.get_custom('Location') or { return error('ACME order Location missing') }
	if order.authorizations.len == 0 { return error('ACME order has no authorizations') }
	for url in order.authorizations { a.authorize(url, cfg, opts)! }
	mut ready := false
	for _ in 0 .. 30 {
		resp := a.post(order_url, '', false)!
		order = json2.decode[AcmeOrder](resp.body)!
		if order.status == 'ready' {
			ready = true
			break
		}
		if order.status != 'pending' {
			return error('ACME order is ${order.status}, expected ready')
		}
		retry_pause(resp)
	}
	if !ready { return error('ACME order did not become ready') }
	csr := base64.url_encode(os.read_bytes(os.join_path(dir, 'csr.der'))!)
	a.post(order.finalize, json2.encode(Finalize{csr}, escape_unicode: true), false)!
	for _ in 0 .. 90 {
		if C.vaddy_stopped() != 0 { return error('shutdown') }
		resp := a.post(order_url, '', false)!
		order = json2.decode[AcmeOrder](resp.body)!
		if order.status == 'valid' {
			pem := a.post(order.certificate, '', false)!
			if !pem.body.starts_with('-----BEGIN CERTIFICATE-----') {
				return error('ACME certificate response is not PEM')
			}
			os.write_file(os.join_path(dir, 'fullchain.pem'), pem.body)!
			return
		}
		if order.status !in ['ready', 'processing'] {
			return error('ACME finalization failed: ${resp.body}')
		}
		retry_pause(resp)
	}
	return error('ACME certificate issuance timed out')
}

fn issue_internal(opts Options, exe string, dir string) ! {
	ca := os.join_path(opts.data, 'pki')
	os.mkdir_all(ca, mode: 0o700)!
	ca_key := os.join_path(ca, 'root.key')
	ca_cert := os.join_path(ca, 'root.crt')
	if !os.exists(ca_key) {
		openssl_command(exe, ['genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256',
			'-out', ca_key])!
	}
	if !os.exists(ca_cert) {
		openssl_command(exe, ['req', '-new', '-x509', '-key', ca_key, '-days', '3650', '-subj',
			'/CN=Vaddy Local Authority', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext',
			'keyUsage=critical,keyCertSign,cRLSign', '-out', ca_cert])!
	}
	serial := hex.encode(crypto_rand.bytes(16)!)
	openssl_command(exe, ['x509', '-req', '-inform', 'DER', '-in', os.join_path(dir, 'csr.der'),
		'-CA', ca_cert, '-CAkey', ca_key, '-set_serial', '0x${serial}', '-days', '30', '-extfile',
		os.join_path(dir, 'extensions'), '-out', os.join_path(dir, 'fullchain.pem')])!
}

fn cert_policy(cfg Config) string {
	site := cfg.tls_site() or { return '' }
	return '${site.tls_mode}\n${cfg.acme_ca}\n${cfg.domains().join('\n')}\n'
}

fn certificate_due(cfg Config, opts Options) bool {
	generation := (os.read_file(os.join_path(opts.data, 'current')) or { return true }).trim_space()
	if !safe_generation(generation) { return true }
	dir := os.join_path(opts.data, generation)
	policy := os.read_file(os.join_path(dir, 'policy')) or { return true }
	if policy != cert_policy(cfg) { return true }
	cert := os.join_path(dir, 'fullchain.pem')
	remaining := C.vaddy_cert_seconds(&char(cert.str), 0)
	lifetime := C.vaddy_cert_seconds(&char(cert.str), 1)
	if remaining <= 0 || lifetime <= 0 || remaining <= lifetime / 3 { return true }
	for domain in cfg.domains() {
		if C.vaddy_cert_host(&char(cert.str), &char(domain.str)) != 1 { return true }
	}
	key := os.join_path(dir, 'key.pem')
	ctx := C.vaddy_tls_context(&char(cert.str), &char(key.str))
	if ctx == unsafe { nil } { return true }
	C.vaddy_tls_ctx_free(ctx)
	return false
}

fn provision_certificate(cfg Config, opts Options, exe string) ! {
	name := 'cert-${time.now().unix()}-${hex.encode(crypto_rand.bytes(6)!)}'
	dir := os.join_path(opts.data, name)
	os.mkdir_all(dir, mode: 0o700)!
	mut published := false
	defer { if !published { os.rmdir_all(dir) or {} } }
	key := os.join_path(dir, 'key.pem')
	san := cfg.domains().map('DNS:${it}').join(',')
	openssl_command(exe, ['genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256',
		'-out', key])!
	openssl_command(exe, ['req', '-new', '-key', key, '-subj', '/CN=${cfg.domains()[0]}', '-addext',
		'subjectAltName=${san}', '-outform', 'DER', '-out', os.join_path(dir, 'csr.der')])!
	os.write_file(os.join_path(dir, 'extensions'), 'subjectAltName=${san}\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n')!
	site := cfg.tls_site() or { return error('no TLS site') }
	if site.tls_mode == 'internal' {
		issue_internal(opts, exe, dir)!
	} else {
		issue_acme(cfg, opts, exe, dir)!
	}
	cert := os.join_path(dir, 'fullchain.pem')
	for domain in cfg.domains() {
		if C.vaddy_cert_host(&char(cert.str), &char(domain.str)) != 1 {
			return error('issued certificate does not cover ${domain}')
		}
	}
	if C.vaddy_cert_seconds(&char(cert.str), 0) <= 0 {
		return error('issued certificate is already expired')
	}
	ctx := C.vaddy_tls_context(&char(cert.str), &char(key.str))
	if ctx == unsafe { nil } { return error('issued certificate does not match private key') }
	C.vaddy_tls_ctx_free(ctx)
	os.write_file(os.join_path(dir, 'policy'), cert_policy(cfg))!
	atomic_write(os.join_path(opts.data, 'current'), name + '\n')!
	published = true
	eprintln('vaddy: certificate issued and stored for ${cfg.domains().join(', ')}')
}

fn certificate_worker(cfg Config, opts Options) {
	exe := openssl_executable() or {
		eprintln('vaddy: ${err}')
		return
	}
	mut retry := 60
	for C.vaddy_stopped() == 0 {
		mut wait_seconds := 3600
		mut failed := false
		if certificate_due(cfg, opts) {
			provision_certificate(cfg, opts, exe) or {
				eprintln('vaddy: certificate automation: ${err}; retry in ${retry}s')
				failed = true
				wait_seconds = retry
				retry = if retry < 1800 { retry * 2 } else { 3600 }
			}
			if !failed { retry = 60 }
		}
		for _ in 0 .. wait_seconds {
			if C.vaddy_stopped() != 0 { return }
			time.sleep(time.second)
		}
	}
}

fn openssl_executable() !string {
	configured := os.getenv('VADDY_OPENSSL')
	return os.find_abs_path_of_executable(if configured == '' { 'openssl' } else { configured })
}
