# Copyright (C) Endpoints Server Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;

################################################################################

BEGIN { use FindBin; chdir($FindBin::Bin); }

use ApiManager;   # Must be first (sets up import path to the Nginx test module)
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework
use HttpServer;

################################################################################

# Port assignments
my $Http2NginxPort = ApiManager::pick_port();
my $HttpBackendPort = ApiManager::pick_port();
my $GrpcBackendPort = ApiManager::pick_port();
my $GrpcFallbackPort = ApiManager::pick_port();

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(4);

$t->write_file('service.pb.txt', ApiManager::get_grpc_test_service_config($GrpcBackendPort));

$t->write_file_expand('nginx.conf', <<"EOF");
%%TEST_GLOBALS%%
daemon off;
events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server {
    listen 127.0.0.1:${Http2NginxPort} http2;
    server_name localhost;
    location / {
      endpoints {
        api service.pb.txt;
        on;
      }
      grpc_pass 127.0.0.2:${GrpcFallbackPort};
    }

  }
}
EOF

$t->run_daemon(\&ApiManager::grpc_test_server, $t, "127.0.0.1:${GrpcBackendPort}");
is($t->waitforsocket("127.0.0.1:${GrpcBackendPort}"), 1, 'GRPC test server socket ready.');
$t->run();
is($t->waitforsocket("127.0.0.1:${Http2NginxPort}"), 1, 'Nginx socket ready.');

################################################################################

my $test_results = &ApiManager::run_grpc_test($t, <<"EOF");
server_addr: "127.0.0.1:${Http2NginxPort}"
direct_addr: "127.0.0.1:${GrpcBackendPort}"
plans {
  probe_upstream_message_limit {
    request {
      text: "Hello, world!  Plus some extra text to add a little length."
    }
    timeout_ms: 1000
  }
}
EOF

$t->stop_daemons();

my $test_results_expected = <<'EOF';
results {
  probe_upstream_message_limit {
    message_limit: (\d+)
  }
}
EOF
like($test_results, qr/$test_results_expected/m, 'Client tests completed as expected.');

if ($test_results =~ /$test_results_expected/) {
  my $message_limit = $1;

  cmp_ok($message_limit, '<', 10000, 'upstream->downstream is throttled');

} else {
  fail('Able to pull out test results');
}
