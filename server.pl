#!/usr/bin/perl
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Log;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::HTTP;

use MIME::Base64;
use Encode qw(decode_utf8 encode_utf8 decode encode _utf8_off _utf8_on);
use JSON::XS;
use Math::Trig;

use Data::Dumper;

$AnyEvent::HTTP::MAX_PER_HOST = 1;
$AnyEvent::Log::FILTER->level('trace');

use constant API_POLL_PERIOD => 1;
use constant SESSION_POLL_PERIOD => 20;
use constant POLL_TIME_PERIOD_EMPTY => 1 * 5 * 60; # in secs

my $host = undef;
my $port = 44244;

my (%connections, %need_route, %route, %next_poll_time);

sub connection_destroy {
        my $handle = shift;

        # Connection is already destroyed
        return unless $connections{$handle};

        my %cur_route_id = %{ $connections{$handle}{route_id} //= {} };
        foreach (keys %cur_route_id) {
                delete $need_route{$_} if not --$need_route{$_};
        }

        delete $connections{$handle};
        $handle->destroy;
}

my %last_coordinates = ();
my %last_updated_coordinates = ();

sub process_route_data {
        my $data = shift;
        # print Dumper($data), "\n\n";

        my $vehicles = $data->{ts};

        if (UNIVERSAL::isa($vehicles, 'HASH')) {
                foreach my $vehicle_id (keys %$vehicles) {
                        my $vehicle = $vehicles->{$vehicle_id};

                        next unless UNIVERSAL::isa($vehicle, 'HASH');

                        $vehicle->{u_course} = 0;

                        unless (exists $last_updated_coordinates{$vehicle_id}) {
                                $last_updated_coordinates{$vehicle_id} = [ 0, 0 ];
                                $last_coordinates{$vehicle_id} = [ 0, 0 ];
                        }
                        else {
                                my $luc = $last_updated_coordinates{$vehicle_id};
                                my $lc = $last_coordinates{$vehicle_id};

                                unless ($luc->[0] == $vehicle->{u_lat} && $luc->[1] == $vehicle->{u_long}) {
                                        $lc->[0] = $luc->[0];
                                        $lc->[1] = $luc->[1];
                                }

                                $vehicle->{u_course} = calculate_course($vehicle->{u_lat}, $vehicle->{u_long}, $lc->[0], $lc->[1]);

                                # always update previous coordinates
                                $luc->[0] = $vehicle->{u_lat};
                                $luc->[1] = $vehicle->{u_long};
                        }
                }
        }

        return $data;
}

sub calculate_course {
        my ($lat, $lng, $lat_prev, $lng_prev) = @_;

        my $latitude1 = $lat_prev * pi / 180;
        my $latitude2 = $lat * pi / 180;
        my $long_diff = ($lng - $lng_prev) * pi / 180;
        my $y = sin($long_diff) * cos($latitude2);
        my $x = cos($latitude1) * sin($latitude2) - sin($latitude1) * cos($latitude2) * cos($long_diff);

        return (atan2($y, $x) * (180 / pi) + 360) % 360;
}

sub handler_get_route {
        my ($handle, $new_route_id) = @_;

        my %new_route_id; @new_route_id{ @$new_route_id } = (undef) x @$new_route_id;
        my %cur_route_id = %{ $connections{$handle}{route_id} //= {} };

        my @intersect;
        foreach ( keys %new_route_id ) {
                push @intersect => $_ if exists $cur_route_id{$_};
        }

        my %inc_need_route_id = %new_route_id;
        delete @inc_need_route_id{ @intersect };
        $need_route{$_}++ foreach keys %inc_need_route_id;

        my %dec_need_route_id = %cur_route_id;
        delete @dec_need_route_id{ @intersect };
        foreach ( keys %dec_need_route_id ) {
                delete $need_route{$_} if not --$need_route{$_};
        }

        $connections{$handle}{route_id} = \%new_route_id;
        $handle->push_write( sprintf( "get_route ok: %s\015\012", join( ',', keys %new_route_id ) ) );

        unless ($connections{$handle}{w_sender}) {
                $connections{$handle}{w_sender} = AnyEvent->timer(after => 1, interval => 3, cb => sub {
                        my %data;
                        my %route_id = %{ $connections{$handle}{route_id} //= {} };
                        foreach ( keys %route_id ) {
                                next if not exists $route{$_} or not UNIVERSAL::isa($route{$_}, 'HASH');
                                $data{$_} = process_route_data($route{$_});
                        }

                        $handle->push_write( encode_json(\%data) . "\015\012" );
                });
        }
}

sub handler_dump_route_data {
        my ($handle, $route_id) = @_;
        $handle->push_write(Dumper(\%route) . "\015\012");
        $handle->push_write( sprintf( "dump_route ok: %s\015\012", join( ',', @$route_id ) ) );
}

my $cv = AE::cv;

tcp_server( $host, $port, sub {
        my ($fh) = @_;
        AE::log info => 'Connected';

        my $handle;
        $handle = AnyEvent::Handle->new(
                fh => $fh,
                poll => 'r',
                on_read => sub {
                        my ($self) = @_;

                        my $recv = $self->rbuf;
                        # Yeah, clean the buffer here
                        $handle->{rbuf} = '';

                        my ($cmd, $arg) = $recv =~ m/^(\w+)(?:\s+(.+?))?\s*$/;
                        return unless $cmd;

                        AE::log info => sprintf("Received (cmd: %s, args: %s)\n", $cmd, $arg);

                        if ($cmd =~ /^get_route|dump_route$/) {
                                my @route_id = grep { defined && /^\d+$/ } split(/,/, $arg);
                                if ($cmd eq 'get_route') {
                                        handler_get_route($handle, \@route_id);
                                } elsif ($cmd eq 'dump_route') {
                                        handler_dump_route_data($handle, \@route_id);
                                }
                        }
                },
                on_error => sub {
                        my ($hdl, $fatal, $msg) = @_;
                        AE::log error => "Connection closed with error: $msg";
                        connection_destroy($hdl);
                },
                on_eof => sub {
                        my ($hdl) = @_;
                        AE::log info => 'Connection closed normally';
                        connection_destroy($hdl);
                },
        );

        # keep it alive
        $connections{$handle} = {
                handle   => $handle,
                route_id => {},
                w_sender => undef,
        };

        $handle->push_write("hello\015\012");

        return;
});

AE::log info => "Listening on port $port\n";

my %cookie_jar = ();
my $sid = undef;

# request url: http://transport.volganet.ru/api/rpc.php
# request method: POST

# request headers
# Accept: application/json, text/plain, */*
# Accept-Encoding: gzip, deflate
# Accept-Language: en-US,en;q=0.9
# Connection: keep-alive
# Content-Length: 132
# Content-Type: application/json
# Host: transport.volganet.ru
# Origin: http://transport.volganet.ru
# Referer: http://transport.volganet.ru/main.php
# User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36

# request body: {"jsonrpc":"2.0","method":"startSession","params":{},"id":1}
#
sub make_session_request {
        my $cb = shift;
        my $body = encode_json({
            jsonrpc => '2.0',
            id => 1,
            method => 'startSession',
            params => {},
        });
        
        http_post
                'http://transport.volganet.ru/api/rpc.php',
                $body,
                cookie_jar => \%cookie_jar,
                headers => {
                        'Accept' => 'application/json, text/plain, */*',
                        'Host' => 'transport.volganet.ru',
                        'Referer' => 'http://transport.volganet.ru/main.php',
                        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36',
                },
                $cb; # sub { my ($data, $headers) = @_; };
}

# request url: http://transport.volganet.ru/api/rpc.php
# request method: POST

# request headers
# Accept: application/json, text/plain, */*
# Accept-Encoding: gzip, deflate
# Accept-Language: en-US,en;q=0.9
# Connection: keep-alive
# Content-Length: 132
# Content-Type: application/json
# Host: transport.volganet.ru
# Origin: http://transport.volganet.ru
# Referer: http://transport.volganet.ru/main.php
# User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36

# request body: {"jsonrpc":"2.0","method":"getUnits","params":{"sid":"9CB8F222-E42D-4ED4-A758-912FCF18D53B","marshList":["174","273","58"]},"id":12}
#
sub make_api_request {
        my ($route_id, $cb) = @_;
        my $body = encode_json({
            jsonrpc => '2.0',
            id => 12,
            method => 'getUnits',
            params => {
                sid => $sid,
                # marshList => ["174","273","58"]
                marshList => $route_id
            },
        });
        
        my $req = http_post
                'http://transport.volganet.ru/api/rpc.php',
                $body,
                headers => {
                        'Accept' => 'application/json, text/plain, */*',
                        'Host' => 'transport.volganet.ru',
                        'Referer' => 'http://transport.volganet.ru/main.php',
                        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36',
                },
                $cb; # sub { my ($data, $headers) = @_; };

        return $req;
}

my $w_session_request_periodic;
sub session_request_periodic {
        $w_session_request_periodic = AnyEvent->timer(after => 1, interval => SESSION_POLL_PERIOD, cb => sub {
                make_session_request(sub {
                        my ($data, $hdr) = @_;
                        if ($hdr->{Status} =~ /^2/) {
                                my $response = decode_json( $data );
                                # {"jsonrpc":"2.0","result":{"sid":"E5B92E2E-A691-413A-A049-5B732B6E0C75"},"id":1}
                                
				if ( UNIVERSAL::isa( $response, 'HASH' ) && UNIVERSAL::isa( $response->{'result'}, 'HASH' ) ) {
                                        $sid = $response->{'result'}->{'sid'};
                                	AE::log info => "Got session OK (sid: $sid)";
				} else {
                                        $sid = undef;
                                        AE::log error => "Got session ERROR, bad response format";
                                }
                        } else {
                                $sid = undef;
                                AE::log error => "Got session ERROR, bad http status: $$hdr{Status}";
                        }
                });
        });
}

my %pending_request;
my $w_poll_needed_route;
sub poll_needed_route {
        $w_poll_needed_route = AnyEvent->timer(after => 1, interval => API_POLL_PERIOD, cb => sub {
                unless ($sid) {
                        AE::log warn => "No sid, skipping request";
                        return;
                }

                if (not scalar keys %need_route) {
                    AE::log info => "No routes are needed, skipping request";
                    return;
                }
                
                my @route_ids = keys %need_route;
                my $request_key = join(',', sort @route_ids);

                if (exists $pending_request{$request_key}) {
                        AE::log info => "Request is already scheduled (key: $request_key)";
                        return;
                }

                if ( ( $next_poll_time{$request_key} ||= 0 ) > scalar time ) {
                        # Skip this request since the next poll time is still in future
                        AE::log info => "Route poll time (key: $request_key) is still in future, skip";
                        return;
                }

                AE::log info => "Request routes (key: $request_key)";
                $pending_request{$request_key} = make_api_request(\@route_ids, sub {
                        my ($data, $hdr) = @_;
                        delete $pending_request{$request_key}; # Yes, anyway
                        if ($hdr->{Status} =~ /^2/) {
                                AE::log info => "Got routes OK (key: $request_key)";
                                eval { _fill_route($data, \@route_ids, $request_key); };
                                if ($@) {
                                        AE::log error => "Fill route ERROR (key: $request_key): $@";
                                }
                        } else {
                                AE::log error => "Got route ERROR (key: $request_key)";
                        }
                });
        });
}

sub _fill_route {
        my ($data, $requested_route_ids, $request_key) = @_;

        my $response = decode_json( $data );
        if ( UNIVERSAL::isa( $response, 'HASH' ) && UNIVERSAL::isa( $response->{'result'}, 'ARRAY' ) ) {
		my %requested_route_ids;
                @requested_route_ids{ @$requested_route_ids } = (undef) x @$requested_route_ids;
		
		use Data::Dumper;
                AE::log info => Dumper($response);
		
		foreach my $r ( @{ $response->{result} } ) {
                        my $route_id = $r->{'mr_id'};
                        next unless $route_id;

                        push @{ $route{$route_id} ||= [] } => $r;
                        delete $requested_route_ids{$route_id};
                }

                foreach my $rotue_id (keys %requested_route_ids) {
                        delete $route{$rotue_id};
                }

                $next_poll_time{$request_key} = 0;
        } else {
                # update next poll time
                $next_poll_time{$request_key} = time + POLL_TIME_PERIOD_EMPTY;
        }
}

session_request_periodic();
poll_needed_route();

$cv->recv;

