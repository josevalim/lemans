# frozen_string_literal: true

require "test_helper"

require "webrick"
require "miniswen"
require "miniswen/local"
require "miniswen/testing"

class MiniswenMCPTest < Minitest::Test
  include Miniswen::Testing

  URL = "http://localhost:3000/tidewave/mcp"

  EVAL_TOOL = {
    "name" => "project_eval", "description" => "Evaluates Ruby code",
    "inputSchema" => { "type" => "object", "properties" => { "code" => { "type" => "string" } }, "required" => [ "code" ] }
  }.freeze

  # A shell whose `ruby -e POST_SCRIPT` answers as an MCP server would, with
  # every other command looked up as in FakeEnv.
  class MCPEnv < FakeEnv
    attr_reader :requests
    attr_accessor :up

    def initialize(tools: [ EVAL_TOOL ], up: true, &handler)
      super()
      @tools = tools
      @up = up
      @handler = handler
      @requests = []
    end

    def exec(command, timeout: nil, env: nil)
      return super unless command.start_with?("ruby -e ")

      @commands << :mcp
      return result(7, "Errno::ECONNREFUSED: Connection refused") unless up

      message = JSON.parse(command.lines[-2])
      @requests << message
      return result(0, "202 \n") unless message["id"]

      result(0, "200 application/json\n#{JSON.generate({ jsonrpc: "2.0", id: message["id"], result: answer(message) })}")
    end

    private

    def answer(message)
      case message["method"]
      when "initialize" then { "protocolVersion" => "2025-03-26", "instructions" => "Use project_eval for the app." }
      when "tools/list" then { "tools" => @tools }
      when "tools/call" then @handler&.call(message["params"]) || { "content" => [ { "type" => "text", "text" => "42" } ] }
      else {}
      end
    end
  end

  def test_tools_are_offered_called_and_observed
    env = MCPEnv.new { |params| { "content" => [ { "type" => "text", "text" => "=> #{params.dig("arguments", "code")}" } ] } }
    stub_llm({ content: "Eval.", tool_calls: [ { name: "mcp__tidewave__project_eval", arguments: { "code" => "1 + 1" } } ] }, SUBMIT)
    agent = Miniswen::Agent.new(model: "test", environment: env, mcp_servers: { "tidewave" => { url: URL } })

    result = agent.run("task")

    assert_equal :submitted, result.status
    assert_equal %w[initialize notifications/initialized tools/list tools/call], env.requests.map { it["method"] }
    assert_equal({ "name" => "project_eval", "arguments" => { "code" => "1 + 1" } }, env.requests.last["params"])
    observation = result.messages.find { it[:role] == "tool" }

    assert_equal "=> 1 + 1", observation[:content]
    assert_equal 0, observation.dig(:observation, :exit_code)
    prompt = result.messages[1][:content]

    assert_includes prompt, "### tidewave"
    assert_includes prompt, "Tools: mcp__tidewave__project_eval"
    assert_includes prompt, "Use project_eval for the app."
    tools = RubyLLM::Test.last_request.tools

    assert_equal %i[bash mcp__tidewave__project_eval], tools.keys
    assert_equal EVAL_TOOL["inputSchema"], tools[:mcp__tidewave__project_eval].params_schema
  end

  def test_tool_errors_and_bad_arguments_reach_the_model
    env = MCPEnv.new { { "content" => [ { "type" => "text", "text" => "NameError" } ], "isError" => true } }
    stub_llm({ content: "Eval.", tool_calls: [ { name: "mcp__tidewave__project_eval", arguments: "{not json" } ] },
             { content: "Eval.", tool_calls: [ { name: "mcp__tidewave__project_eval", arguments: { "code" => "nope" } } ] }, SUBMIT)
    agent = Miniswen::Agent.new(model: "test", environment: env, mcp_servers: { "tidewave" => { url: URL } })

    result = agent.run("task")

    assert_equal :submitted, result.status
    assert(result.messages.any? { it[:role] == "user" && it[:content].include?("not a valid JSON object") })
    observation = result.messages.find { it[:role] == "tool" }

    assert_equal "NameError", observation[:content]
    assert_equal 1, observation.dig(:observation, :exit_code)
  end

  def test_a_server_without_a_start_command_must_already_answer
    env = MCPEnv.new(up: false)
    agent = Miniswen::Agent.new(model: "test", environment: env, mcp_servers: { "tidewave" => { url: URL } })

    error = assert_raises(Miniswen::InfrastructureError) { agent.run("task") }

    assert_includes error.message, "MCP server tidewave is unreachable at #{URL}"
  end

  def test_a_start_command_boots_the_server_and_reboots_it_once_it_goes_away
    env = MCPEnv.new(up: false)
    boot = "setsid sh -c bin/rails\\ server > /tmp/miniswen-mcp-tidewave.log 2>&1 < /dev/null & echo $!"
    env.on(boot, "4242\n")
    server = Miniswen::MCP.new(name: "tidewave", url: URL, start: "bin/rails server", environment: env)
    booting = env.method(:exec)
    env.define_singleton_method(:exec) do |command, **options|
      self.up = true if command == boot
      booting.call(command, **options)
    end

    server.connect!

    assert_equal [ "mcp__tidewave__project_eval" ], server.tools.keys
    assert_includes env.commands, boot
    env.up = false
    env.commands.clear

    outcome = server.call("mcp__tidewave__project_eval", { "code" => "1" })

    refute outcome.error
    assert_equal "42", outcome.text
    assert_equal [ :mcp, "kill -TERM -- -4242 2>/dev/null; true", boot ], env.commands.first(3)
    server.stop

    assert_equal "kill -TERM -- -4242 2>/dev/null; true", env.commands.last
  end

  def test_the_request_script_posts_through_a_real_shell
    received = []
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(IO::NULL), AccessLog: [])
    server.mount_proc("/mcp") do |request, response|
      message = JSON.parse(request.body)
      received << [ message["method"], request["mcp-protocol-version"] ]
      result = message["method"] == "tools/list" ? { "tools" => [ EVAL_TOOL ] } : {}
      response["content-type"] = "text/event-stream"
      response.body = "event: message\ndata: #{JSON.generate({ jsonrpc: "2.0", id: message["id"], result: })}\n\n"
    end
    thread = Thread.new { server.start }

    mcp = Miniswen::MCP.new(name: "local", url: "http://127.0.0.1:#{server.config[:Port]}/mcp",
                            environment: Miniswen::Local.new, timeout: 10)
    mcp.connect!

    assert_equal [ "mcp__local__project_eval" ], mcp.tools.keys
    assert_equal [ %w[initialize 2025-03-26], %w[notifications/initialized 2025-03-26], %w[tools/list 2025-03-26] ], received
  ensure
    server&.shutdown
    thread&.join
  end
end
