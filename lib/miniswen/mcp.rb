# frozen_string_literal: true

require "json"
require "securerandom"
require "shellwords"
require "miniswen/ruby_llm"

module Miniswen
  # A client for an MCP server speaking the stateless Streamable HTTP
  # transport: every JSON-RPC request is one POST, with no session to keep.
  #
  # Requests go through the environment, not a socket of the agent's own: the
  # server runs next to the commands (a jail has its own network namespace, a
  # remote sandbox its own host), so its loopback is only reachable from there.
  class MCP
    PROTOCOL_VERSION = "2025-03-26"
    TOOL_PREFIX = "mcp"
    CONNECT_ATTEMPT_INTERVAL = 2

    # Posts stdin to ARGV[0] with no proxy (an MCP server is local) and prints
    # the status and content type on the first line, the body after it.
    POST_SCRIPT = <<~'RUBY'
      require "net/http"
      begin
        uri = URI(ARGV[0])
        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = Float(ARGV[1])
        response = http.post(uri.request_uri, $stdin.read,
                             "content-type" => "application/json",
                             "accept" => "application/json, text/event-stream",
                             "mcp-protocol-version" => ARGV[2])
        print response.code, " ", response["content-type"], "\n", response.body
      rescue SystemCallError, IOError, Timeout::Error, SocketError => e
        print "#{e.class}: #{e.message}"
        exit 7
      end
    RUBY

    # Rendered into the request only: the agent calls #call, not the tool.
    class Tool < RubyLLM::Tool
      attr_reader :name, :description, :params_schema, :remote_name

      def initialize(name:, description:, params_schema:, remote_name:)
        super()
        @name = name
        @description = description
        @params_schema = params_schema
        @remote_name = remote_name
      end
    end

    Response = Data.define(:status, :content_type, :body)
    Outcome = Data.define(:error, :text)

    # Not a Miniswen::Error: miniswen.rb loads this file before defining it.
    class Unreachable < StandardError; end

    attr_reader :name, :url, :start, :instructions, :tools

    private attr_reader :environment, :timeout, :boot_timeout, :clock

    def initialize(name:, url:, environment:, start: nil, timeout: 300, boot_timeout: 180,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @name = name
      @url = url
      @environment = environment
      @start = start
      @timeout = timeout
      @boot_timeout = boot_timeout
      @clock = clock

      @tools = {}

      @pid = nil
      @request_id = 0
    end

    # Boots the server first if it has a start command and is not up yet;
    # raises InfrastructureError when it never answers.
    def connect!
      handshake
      @tools = list_tools.to_h { [ it.name, it ] }
      self
    end

    def tool?(name) = tools.key?(name)

    # A server that went away (say, the agent killed it, or a change broke
    # its boot) is booted again once; a call that still fails is the model's
    # observation, not the harness's failure.
    def call(tool_name, arguments)
      tool = tools.fetch(tool_name)
      result = begin
        rpc("tools/call", { name: tool.remote_name, arguments: })
      rescue Unreachable
        raise unless start

        boot
        rpc("tools/call", { name: tool.remote_name, arguments: })
      end
      Outcome.new(error: result["isError"] == true, text: content_text(result["content"]))
    rescue Error, Unreachable => e
      Outcome.new(error: true, text: "MCP server #{name} failed: #{e.message}#{server_log_tail}")
    end

    def stop
      environment.exec("kill -TERM -- -#{@pid} 2>/dev/null; true", timeout: 10) if @pid
      @pid = nil
    end

    def log_path = "/tmp/miniswen-mcp-#{name}.log"

    private

    def handshake
      initialize_server
    rescue Unreachable => e
      raise InfrastructureError, "MCP server #{name} is unreachable at #{url}: #{e.message}" unless start

      boot
      initialize_server
    end

    def initialize_server
      result = rpc("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                                   clientInfo: { name: "miniswen", version: VERSION } })
      @instructions = result["instructions"]
      notify("notifications/initialized")
    end

    def list_tools
      tools = []
      cursor = nil
      loop do
        result = rpc("tools/list", cursor ? { cursor: } : {})
        tools.concat(Array(result["tools"]))
        break unless (cursor = result["nextCursor"])
      end

      tools.map do |tool|
        Tool.new(name: "#{TOOL_PREFIX}__#{name}__#{tool.fetch("name")}", remote_name: tool.fetch("name"),
                 description: tool["description"].to_s,
                 params_schema: tool["inputSchema"] || { "type" => "object", "properties" => {} })
      end
    end

    # The process group is its own session, so a step's exec returning (or
    # timing out) leaves the server running until #stop.
    def boot
      stop
      launched = environment.exec(
        "setsid sh -c #{Shellwords.escape(start)} > #{log_path} 2>&1 < /dev/null & echo $!", timeout: 30
      )
      @pid = Integer(launched.output.to_s.strip.lines.last.to_s, exception: false)
      raise InfrastructureError, "MCP server #{name} did not start: #{launched.output}" unless launched.success? && @pid

      wait_until_up
    end

    def wait_until_up
      deadline = clock.call + boot_timeout
      begin
        rpc("ping", {})
      rescue Error
        nil # an error reply still means the server is up
      rescue Unreachable => e
        if clock.call >= deadline || !alive?
          raise InfrastructureError,
                "MCP server #{name} did not come up at #{url} (#{e.message})#{server_log_tail}"
        end

        sleep CONNECT_ATTEMPT_INTERVAL
        retry
      end
    end

    def alive? = environment.exec("kill -0 #{@pid}", timeout: 10).success?

    def server_log_tail
      return "" unless start

      tail = environment.exec("tail -n 30 #{log_path}", timeout: 10).output.to_s.strip
      tail.empty? ? "" : "\nServer log (#{log_path}):\n#{tail}"
    end

    def rpc(method, params)
      id = (@request_id += 1)
      message = parse_message(post({ jsonrpc: "2.0", id:, method:, params: }), id)
      if (error = message["error"])
        raise Error, "#{method}: #{error["message"]} (#{error["code"]})"
      end

      message.fetch("result")
    end

    def notify(method) = post({ jsonrpc: "2.0", method: })

    def post(message)
      delimiter = "MINISWEN_MCP_#{SecureRandom.hex(8)}"
      command = [ "ruby", "-e", POST_SCRIPT, url, timeout, PROTOCOL_VERSION ].map { Shellwords.escape(it.to_s) }.join(" ")
      run = environment.exec("#{command} <<'#{delimiter}'\n#{JSON.generate(message)}\n#{delimiter}", timeout: timeout + 10)
      raise Unreachable, run.output.to_s.strip unless run.success?

      head, body = run.output.to_s.split("\n", 2)
      status, content_type = head.to_s.split(" ", 2)
      response = Response.new(status: status.to_i, content_type: content_type.to_s, body: body.to_s)
      # A server still booting may answer before its routes are drawn.
      raise Unreachable, "HTTP #{response.status}" if [ 404, 502, 503 ].include?(response.status)

      response
    end

    def parse_message(response, id)
      unless (200..299).cover?(response.status)
        raise Error, "HTTP #{response.status}: #{response.body[0, 500]}"
      end

      messages =
        if response.content_type.start_with?("text/event-stream")
          response.body.scan(/^data: ?(.*)$/).map { JSON.parse(it.first) }
        else
          parsed = JSON.parse(response.body)
          parsed.is_a?(Array) ? parsed : [ parsed ]
        end
      messages.find { it.is_a?(Hash) && it["id"] == id } or raise Error, "no response to request #{id}"
    rescue JSON::ParserError => e
      raise Error, "invalid JSON from the server: #{e.message}"
    end

    def content_text(content)
      Array(content).map do |item|
        case item["type"]
        when "text" then item["text"].to_s
        when "resource" then item.dig("resource", "text").to_s
        else "[#{item["type"]} content omitted]"
        end
      end.join("\n")
    end
  end
end
