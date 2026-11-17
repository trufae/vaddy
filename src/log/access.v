module log

pub struct TLS {
pub:
	resumed bool
	version int
	cipher_suite int
	proto string
	server_name string
	ech bool
}

pub struct Request {
pub:
	remote_ip string
	remote_port string
	client_ip string
	proto string
	method string
	host string
	uri string
	headers map[string][]string
	transfer_encoding []string @[omitempty]
	tls ?TLS
}

pub struct Record {
pub:
	level string
	ts f64
	logger string
	msg string = 'handled request'
	request Request
	bytes_read i64
	user_id string
	duration f64
	size i64
	status int
	resp_headers map[string][]string
}
