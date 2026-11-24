module main

// Fixed responses are held in memory, then sent through the bounded I/O queues.
const respond_body_limit = 1024 * 1024

fn validate_respond_body(body string) ! {
	if body.len > respond_body_limit {
		return error('respond body exceeds ${respond_body_limit} bytes')
	}
}

fn (mut c Connection) pump_local_body() {
	if c.local_body == '' { return }
	remaining := int(c.response.frame.remaining)
	size := if remaining < c.to_client.room() { remaining } else { c.to_client.room() }
	if size <= 0 { return }
	start := c.local_body.len - remaining
	c.to_client.write_string_range(c.local_body, start, start + size)
	c.response.frame.remaining -= size
	if c.response.frame.remaining == 0 {
		c.local_body = ''
		c.response.frame.done = true
	}
}
