module main

import os
import json2
import net.http
import encoding.base64
import crypto.sha256

fn test_atomic_publication_replaces_existing_file() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-publication-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'current')
	atomic_write(path, 'first')!
	atomic_write(path, 'second')!
	assert os.read_file(path)! == 'second'
	assert !os.exists(path + '.tmp')
}

fn test_storage_lock_is_exclusive_and_released() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-lock-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'lock')
	first := C.vaddy_lock(&char(path.str))
	assert first >= 0
	second := C.vaddy_lock(&char(path.str))
	if second >= 0 { C.vaddy_unlock(second) }
	C.vaddy_unlock(first)
	assert second < 0
	third := C.vaddy_lock(&char(path.str))
	assert third >= 0
	C.vaddy_unlock(third)
}

struct ProtectedJwk {
	e   string
	kty string
	n   string
}

struct ProtectedJws {
	alg   string
	nonce string
	url   string
	kid   string
	jwk   ProtectedJwk
}

@[heap]
struct MockAcme {
mut:
	dir             string
	exe             string
	account_dir     string
	nonce           int
	bad_nonce       bool = true
	challenge_valid bool
	finalized       bool
	processing      bool
	posts           int
	thumbprint      string
	pem             string
}

fn (mut m MockAcme) response(code int, body string, location string) !http.Response {
	m.nonce++
	mut header := http.new_header(key: .content_type, value: 'application/json')
	header.add_custom('Replay-Nonce', 'nonce-${m.nonce}')!
	header.add_custom('Retry-After', '1')!
	if location != '' { header.add_custom('Location', location)! }
	return http.Response{ status_code: code, body: body, header: header }
}

fn (mut m MockAcme) send(method http.Method, url string, data string) !http.Response {
	base := 'https://acme.invalid'
	if method == .get {
		assert url == '${base}/directory'
		return m.response(200, '{"newNonce":"${base}/nonce","newAccount":"${base}/account","newOrder":"${base}/new-order"}', '')
	}
	if method == .head {
		assert url == '${base}/nonce'
		return m.response(204, '', '')
	}
	assert method == .post
	m.posts++
	jws := json2.decode[Jws](data)!
	protected := json2.decode[ProtectedJws](base64.url_decode_str(jws.protected))!
	assert protected.alg == 'RS256'
	assert protected.url == url
	assert protected.nonce == 'nonce-${m.nonce}'
	assert !jws.protected.contains('=') && !jws.signature.contains('=')
	payload := base64.url_decode_str(jws.payload)
	if url == '${base}/account' {
		assert protected.kid == ''
		assert protected.jwk.e == 'AQAB' && protected.jwk.kty == 'RSA'
		canonical := '{"e":"AQAB","kty":"RSA","n":"${protected.jwk.n}"}'
		m.thumbprint = base64.url_encode(sha256.sum(canonical.bytes()))
		assert payload.contains('"termsOfServiceAgreed":true')
		assert payload.contains('mailto:admin@example.org')
	} else {
		assert protected.kid == '${base}/account/1'
	}
	// Verify the actual JWS signature independently using the exported account public key.
	pubkey := os.join_path(m.dir, 'public.pem')
	openssl_command(m.exe, ['pkey', '-in', os.join_path(m.account_dir, 'account.key'), '-pubout',
		'-out', pubkey])!
	os.write_file(os.join_path(m.dir, 'verify.input'), '${jws.protected}.${jws.payload}')!
	os.write_file_array(os.join_path(m.dir, 'verify.sig'), base64.url_decode(jws.signature))!
	openssl_command(m.exe, ['dgst', '-sha256', '-verify', pubkey, '-signature',
		os.join_path(m.dir, 'verify.sig'), os.join_path(m.dir, 'verify.input')])!
	if m.bad_nonce {
		m.bad_nonce = false
		return m.response(400, '{"type":"urn:ietf:params:acme:error:badNonce"}', '')
	}
	match url {
		'${base}/account' { return m.response(201, '{}', '${base}/account/1') }
		'${base}/new-order' {
			assert payload.contains('"type":"dns"') && payload.contains('"value":"localhost"')
			return m.response(201, '{"status":"pending","authorizations":["${base}/auth/1"],"finalize":"${base}/finalize"}', '${base}/order/1')
		}
		'${base}/auth/1' {
			assert payload == '' // RFC 8555 POST-as-GET has an empty payload, not {}.
			status := if m.challenge_valid { 'valid' } else { 'pending' }
			return m.response(200, '{"status":"${status}","identifier":{"type":"dns","value":"localhost"},"challenges":[{"type":"http-01","url":"${base}/challenge","token":"test-token-0123456789"}]}', '')
		}
		'${base}/challenge' {
			assert payload == '{}'
			key_auth := os.read_file(os.join_path(m.dir, 'challenges', 'test-token-0123456789'))!
			assert key_auth == 'test-token-0123456789.${m.thumbprint}'
			m.challenge_valid = true
			return m.response(200, '{"status":"processing"}', '')
		}
		'${base}/order/1' {
			assert payload == ''
			if !m.finalized {
				return m.response(200, '{"status":"ready","finalize":"${base}/finalize"}', '')
			}
			if !m.processing {
				m.processing = true
				return m.response(200, '{"status":"processing"}', '')
			}
			return m.response(200, '{"status":"valid","certificate":"${base}/cert"}', '')
		}
		'${base}/finalize' {
			final := json2.decode[Finalize](payload)!
			csr := os.join_path(m.dir, 'request.der')
			cert := os.join_path(m.dir, 'issued.pem')
			os.write_file_array(csr, base64.url_decode(final.csr))!
			openssl_command(m.exe, ['x509', '-req', '-inform', 'DER', '-in', csr, '-CA',
				os.join_path(m.dir, 'root.crt'), '-CAkey', os.join_path(m.dir, 'root.key'),
				'-set_serial', '42', '-days', '2', '-copy_extensions', 'copy', '-out', cert])!
			m.pem = os.read_file(cert)!
			m.finalized = true
			return m.response(200, '{"status":"processing"}', '')
		}
		'${base}/cert' {
			assert payload == ''
			return m.response(200, m.pem, '')
		}
		else { return error('unexpected ACME request ${url}') }
	}
}

fn test_acme_signed_order_bad_nonce_challenge_finalize_and_persistence() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-acme-${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'challenges'))!
	defer { os.rmdir_all(dir) or {} }
	C.vaddy_private_files()
	exe := openssl_executable()!
	openssl_command(exe, ['req', '-new', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
		'-nodes', '-subj', '/CN=Test CA', '-days', '3', '-keyout', os.join_path(dir, 'root.key'),
		'-out', os.join_path(dir, 'root.crt')])!
	cfg := parse_config('{\n acme_ca https://acme.invalid/directory\n email admin@example.org\n}\nlocalhost {\n reverse_proxy localhost:8001\n}')!
	mut mock := &MockAcme{ dir: dir, exe: exe, account_dir: os.join_path(dir, 'accounts', sha256.hexhash(cfg.acme_ca)[..16]) }
	opts := Options{
		data:           dir
		acme_transport: fn [mut mock] (method http.Method, url string, data string) !http.Response {
			return mock.send(method, url, data)
		}
	}
	provision_certificate(cfg, opts, exe)!
	assert mock.finalized && mock.posts >= 9 && !mock.bad_nonce
	assert !certificate_due(cfg, opts)
	assert !os.exists(os.join_path(dir, 'challenges', 'test-token-0123456789'))
	key_before := os.read_file(os.join_path(mock.account_dir, 'account.key'))!
	new_acme(cfg, opts, exe)!
	assert os.read_file(os.join_path(mock.account_dir, 'account.key'))! == key_before
	assert os.read_file(os.join_path(mock.account_dir, 'account.url'))! == 'https://acme.invalid/account/1'
	// Switching issuer must trigger issuance and must not silently reuse a staging certificate.
	mut other := cfg
	other.acme_ca = 'https://other.invalid/directory'
	assert certificate_due(other, opts)
}
