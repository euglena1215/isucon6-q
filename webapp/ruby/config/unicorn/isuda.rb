worker_processes 5
preload_app true
timeout 120

listen "/tmp/sockets/isuda.sock"
pid "/tmp/pids/isuda.pid"
