# frozen_string_literal: true

require "fileutils"
require "socket"
require "uri"

module Miniswen
  class Jail < Local
    # An HTTP CONNECT proxy that lets jailed commands reach the allowed hosts only.
    class Proxy
      def self.forward(port, socket)
        server = TCPServer.new("127.0.0.1", port)
        exit!(0) if fork
        serve(server) { pump(it, UNIXSocket.new(socket)) }
      end

      def self.serve(server)
        Thread.report_on_exception = false
        loop { Thread.new(server.accept) { yield it } }
      end

      def self.pump(client, upstream)
        Thread.new do
          IO.copy_stream(client, upstream)
          upstream.close_write
        end
        IO.copy_stream(upstream, client)
      ensure
        client.close
        upstream.close
      end

      def initialize(hosts:, socket:, upstream_proxy: ENV["https_proxy"] || ENV["HTTPS_PROXY"])
        @hosts = hosts
        @socket = socket
        @upstream_proxy = upstream_proxy && !upstream_proxy.empty? ? URI(upstream_proxy) : nil
      end

      def start
        FileUtils.rm_f(@socket)
        server = UNIXServer.new(@socket)
        @pid = fork { self.class.serve(server) { handle(it) } }
        self
      end

      def stop
        Process.kill(:KILL, @pid)
        Process.wait(@pid)
      end

      def handle(client)
        _, target = client.gets("\r\n\r\n").split(" ", 3)
        host, port = target.split(":", 2)
        return client.write("HTTP/1.1 403 Forbidden\r\n\r\n") unless @hosts.include?(host)

        upstream = open_upstream(host, port)
        return client.write("HTTP/1.1 502 Bad Gateway\r\n\r\n") unless upstream

        client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
        self.class.pump(client, upstream)
      ensure
        client.close
      end

      private

      # A sandbox whose egress is itself a proxy (lemans' Docker allowlist) has
      # no direct route out: the tunnel goes through that proxy.
      def open_upstream(host, port)
        return Socket.tcp(host, port.to_i, connect_timeout: 10) unless @upstream_proxy

        upstream = Socket.tcp(@upstream_proxy.host, @upstream_proxy.port, connect_timeout: 10)
        upstream.write("CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n")
        return upstream if upstream.gets("\r\n\r\n").to_s.split(" ", 3)[1] == "200"

        upstream.close
        nil
      end
    end
  end
end
