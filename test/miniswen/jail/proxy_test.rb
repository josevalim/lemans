# frozen_string_literal: true

require "test_helper"
require "miniswen/jail"

class MiniswenJailProxyTest < Minitest::Test
  def connect(hosts, request, upstream_proxy: nil)
    client, server = UNIXSocket.pair
    client.write(request)
    client.close_write
    Miniswen::Jail::Proxy.new(hosts: hosts, socket: "/nonexistent", upstream_proxy:).handle(server)
    client.read
  end

  def test_only_connect_to_a_listed_host_goes_through
    assert_equal "HTTP/1.1 403 Forbidden\r\n\r\n", connect([ "example.com" ], "CONNECT evil.example.net:443 HTTP/1.1\r\n\r\n")
    assert_equal "HTTP/1.1 403 Forbidden\r\n\r\n", connect([ "example.com" ], "CONNECT sub.example.com:443 HTTP/1.1\r\n\r\n")
    assert_equal "HTTP/1.1 403 Forbidden\r\n\r\n", connect([ "example.com" ], "GET http://example.com/ HTTP/1.1\r\n\r\n")
  end

  def test_a_tunnel_goes_through_the_upstream_proxy
    upstream = TCPServer.new("127.0.0.1", 0)
    requests = []
    replies = [ "HTTP/1.1 200 Connection established\r\n\r\nhello", "HTTP/1.1 403 Forbidden\r\n\r\n" ]
    thread = Thread.new do
      replies.each do |reply|
        socket = upstream.accept
        requests << socket.gets("\r\n\r\n")
        socket.write(reply)
        socket.close
      end
    end
    proxy = "http://127.0.0.1:#{upstream.addr[1]}"

    tunneled = connect([ "example.com" ], "CONNECT example.com:443 HTTP/1.1\r\n\r\n", upstream_proxy: proxy)
    refused = connect([ "example.com" ], "CONNECT example.com:443 HTTP/1.1\r\n\r\n", upstream_proxy: proxy)
    thread.join

    assert_equal "HTTP/1.1 200 Connection Established\r\n\r\nhello", tunneled
    assert_equal "HTTP/1.1 502 Bad Gateway\r\n\r\n", refused
    assert_equal [ "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n" ] * 2, requests
  ensure
    upstream&.close
  end
end
