# frozen_string_literal: true

module Miniswen
  module Providers
    # Meta's Model API (the Muse models) through its Anthropic-compatible
    # Messages protocol: Muse's reasoning only carries across turns when its
    # redacted_thinking blocks are replayed, which Chat Completions cannot
    # do. ruby_llm ships no provider for it, nor its models.
    class Meta < RubyLLM::Providers::Anthropic
      # Prices from https://dev.meta.ai/docs/pricing-rate-limits: the
      # contributor variants are the same models, discounted in exchange for
      # Meta training on the traffic.
      MODELS = {
        "muse-spark-1.3" => { input: 1.25, cached: 0.15, output: 4.25 },
        "muse-spark-1.3-contributor" => { input: 0.10, cached: 0.002, output: 0.20 }
      }.to_h do |id, price|
        [ id, RubyLLM::Model::Info.new(
          id:, name: id, provider: "meta",
          capabilities: %w[function_calling reasoning],
          modalities: { input: %w[text], output: %w[text] },
          reasoning_options: [ { type: "effort", values: %w[low medium high xhigh] } ],
          pricing: { text_tokens: { standard: {
            input_per_million: price[:input], cached_input_per_million: price[:cached],
            output_per_million: price[:output]
          } } }
        ) ]
      end.freeze

      # Serves MODELS from ruby_llm's registry lookups, which a refresh would
      # otherwise not know.
      module FindModels
        def find(model_id, provider = nil)
          (provider.nil? || provider.to_s == "meta") && MODELS[model_id] || super
        end
      end

      def api_base = @config.muse_api_base || "https://api.meta.ai"

      # Requests carry a model resolved without the registry (miniswen resolves
      # assuming it exists); MODELS knows which efforts it takes.
      def render_payload(messages, model:, **) = super(messages, model: MODELS.fetch(model.id, model), **)

      def headers = { "Authorization" => "Bearer #{@config.muse_api_key}", "anthropic-version" => "2023-06-01" }

      class << self
        def slug = "meta"

        def configuration_options = %i[muse_api_key muse_api_base]

        def configuration_requirements = %i[muse_api_key]
      end
    end
  end
end

RubyLLM::Provider.register(:meta, Miniswen::Providers::Meta)
RubyLLM::Models.prepend(Miniswen::Providers::Meta::FindModels)
