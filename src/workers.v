module main

import sync.stdatomic

// Only connection ownership crosses reactors. Requests and their buffers stay
// on one worker; the shared counters change only on admission, close and shutdown.
@[heap]
struct WorkerPool {
mut:
	active   i64
	stopping i64
	inboxes  []chan &Connection
	wake_fds []int
	threads  []thread
}

fn (s &Server) active_clients() int {
	return int(stdatomic.load_i64(&s.pool.active))
}

fn (mut s Server) register_client(mut c Connection) {
	if s.draining {
		s.close_client(mut c)
		return
	}
	s.clients[c.fd] = c
	s.owners[c.fd] = c.fd
	if c.backend >= 0 { s.owners[c.backend] = c.fd }
	s.watch(c.fd, 1) or { s.close_client(mut c) }
}

fn (mut s Server) dispatch_client(mut c Connection) {
	if s.active_clients() >= s.opts.max_connections {
		s.close_client(mut c)
		return
	}
	stdatomic.add_i64(&s.pool.active, 1)
	c.counted = true
	slot := s.next_worker
	s.next_worker = (slot + 1) % (s.pool.inboxes.len + 1)
	if slot == 0 {
		s.register_client(mut c)
		return
	}
	// A queue can hold the entire global connection limit, so admitted connections
	// cannot exhaust it. Publish ownership before sending the readiness notification.
	s.pool.inboxes[slot - 1] <- c
	if C.vaddy_notify(s.pool.wake_fds[slot - 1]) != 0 {
		stdatomic.store_i64(&s.pool.stopping, 1)
	}
}

fn (mut s Server) drain_incoming() {
	mut bytes := [256]u8{}
	for C.vaddy_recv(s.control_fd, &bytes[0], uint(bytes.len), 0) > 0 {
	}
	for {
		select {
			received := <-s.incoming {
				mut c := unsafe { received }
				s.register_client(mut c)
			}
			else {
				break
			}
		}
	}
}

fn (mut s Server) start_workers() ! {
	count := if s.opts.workers < s.opts.max_connections {
		s.opts.workers
	} else {
		s.opts.max_connections
	}
	for _ in 1 .. count {
		mut fds := [2]i64{}
		if C.vaddy_wakeup_pair(&fds[0]) != 0 { return error('cannot create worker wakeup sockets') }
		queue := C.vaddy_queue()
		if queue < 0 {
			C.vaddy_close(fds[0])
			C.vaddy_close(fds[1])
			return error('cannot create worker event queue')
		}
		incoming := chan &Connection{cap: s.opts.max_connections}
		mut worker := &Server{
			cfg:        s.cfg
			opts:       s.opts
			queue:      queue
			http_fd:    -1
			control_fd: int(fds[0])
			incoming:   incoming
			pool:       s.pool
			runtime_store: s.runtime_store
			backends:   s.backends
			access_logs: s.access_logs
		}
		worker.watch(int(fds[0]), 1) or {
			C.vaddy_queue_close(queue)
			C.vaddy_close(fds[0])
			C.vaddy_close(fds[1])
			return err
		}
		s.pool.inboxes << incoming
		s.pool.wake_fds << int(fds[1])
		s.pool.threads << spawn worker.serve_worker()
	}
}

fn (mut s Server) serve_worker() {
	s.serve_events() or {
		eprintln('vaddy: worker failed: ${err}')
		stdatomic.store_i64(&s.pool.stopping, 1)
	}
	s.draining = true
	s.drain_incoming()
	for _, mut c in s.clients.clone() { s.close_client(mut c) }
	C.vaddy_close(s.control_fd)
	C.vaddy_queue_close(s.queue)
}

fn (mut s Server) stop_workers() {
	stdatomic.store_i64(&s.pool.stopping, 1)
	for fd in s.pool.wake_fds { C.vaddy_notify(fd) }
	s.pool.threads.wait()
	for i, inbox in s.pool.inboxes {
		// Also release queued connections if a worker failed before seeing its wakeup.
		for {
			select {
				received := <-inbox {
					mut c := unsafe { received }
					s.close_client(mut c)
				}
				else {
					break
				}
			}
		}
		C.vaddy_close(s.pool.wake_fds[i])
	}
	s.pool.threads.clear()
	s.pool.inboxes.clear()
	s.pool.wake_fds.clear()
}
