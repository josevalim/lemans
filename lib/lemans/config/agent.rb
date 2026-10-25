# frozen_string_literal: true

module Lemans
  class Config
    class Agent # :nodoc:
      class << self
        include Conversion

        def from_config(data)
          return if data.nil?

          name = data.fetch("name")
          model = data.fetch("model")

          conf = new(name, model)

          conf.step_limit = integer!(data["step_limit"]) if data["step_limit"]
          conf.cost_limit = float!(data["cost_limit"]) if data["cost_limit"]
          conf.timeout = seconds!(data["timeout"]) if data["timeout"]
          conf.exec_timeout = seconds!(data["exec_timeout"]) if data["exec_timeout"]
          conf.max_output_tokens = integer!(data["max_output_tokens"]) if data.key?("max_output_tokens")

          data["mcp_servers"]&.each { |server_name, entry| conf.mcp_servers[server_name] = mcp_server!(server_name, entry) }

          if (network_data = data.dig("environment", "network"))
            conf.environment = Environment.new(network: NetworkPolicy.from_config(network_data))
          end

          conf
        rescue KeyError => e
          raise ConfigError, "agent.#{e.key} must be provided"
        end

        private

        def mcp_server!(name, entry)
          raise ConfigError, "agent.mcp_servers.#{name}.url must be provided" unless entry&.dig("url")

          MCPServer.new(url: entry["url"], start: entry["start"])
        end
      end

      attr_accessor :name, :models, :timeout,
                    :step_limit, :cost_limit, :exec_timeout, :max_output_tokens,
                    :environment, :mcp_servers

      def model = models.first

      def to_h
        {
          "name" => name,
          "model" => models,
          "timeout" => timeout,
          "step_limit" => step_limit,
          "cost_limit" => cost_limit,
          "exec_timeout" => exec_timeout,
          "max_output_tokens" => max_output_tokens,
          "environment" => { "network" => environment.network.to_h },
          "mcp_servers" => (mcp_servers.transform_values { it.to_h.transform_keys(&:to_s).compact } if mcp_servers.any?)
        }.compact
      end

      Environment = Struct.new(:network, keyword_init: true)
      MCPServer = Struct.new(:url, :start, keyword_init: true)

      def initialize(name, model)
        @name = name
        @models = Array(model)
        @step_limit = 100
        @cost_limit = nil
        @exec_timeout = 300
        @max_output_tokens = 0
        @timeout = 30 * 60
        @environment = Environment.new(network: NetworkPolicy.new)
        @mcp_servers = {}
      end
    end
  end
end
