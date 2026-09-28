# frozen_string_literal: true

# Account identifiers are personal banking data and must never reach the logs (PLAN structured-logging).
RSpec.describe "SensitiveParameterFiltering" do
  let(:parameter_filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "hides organization and counterparty IBANs and BICs from logged parameters" do
    bulk_request = JSON.parse(file_fixture("sample1.json").read)

    filtered_request = parameter_filter.filter(bulk_request)

    expect(filtered_request.values_at("organization_iban", "organization_bic")).to all(eq("[FILTERED]"))
    filtered_request["credit_transfers"].each do |credit_transfer|
      expect(credit_transfer.values_at("counterparty_iban", "counterparty_bic")).to all(eq("[FILTERED]"))
    end
  end

  it "keeps non-sensitive fields readable for debugging" do
    bulk_request = JSON.parse(file_fixture("sample1.json").read)

    filtered_request = parameter_filter.filter(bulk_request)

    expect(filtered_request["credit_transfers"].first).to include("amount" => "14.5", "currency" => "EUR")
  end
end
