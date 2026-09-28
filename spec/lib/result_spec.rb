# frozen_string_literal: true

RSpec.describe Result do
  describe ".success" do
    it "carries the value and no errors" do
      result = described_class.success(:bulk_transfer)

      expect(result).to have_attributes(value: :bulk_transfer, errors: [], successful?: true, failed?: false)
    end

    it "is not an idempotent replay by default" do
      result = described_class.success(:bulk_transfer)

      expect(result).not_to be_idempotent_replay
    end

    it "flags an idempotent replay when asked to" do
      result = described_class.success(:bulk_transfer, idempotent_replay: true)

      expect(result).to be_idempotent_replay
    end
  end

  describe ".failure" do
    it "carries the error and no value" do
      error = StandardError.new("boom")

      result = described_class.failure(error)

      expect(result).to have_attributes(value: nil, errors: [error], successful?: false, failed?: true)
    end

    it "is never an idempotent replay" do
      result = described_class.failure(StandardError.new("boom"))

      expect(result).not_to be_idempotent_replay
    end
  end

  it "is frozen, errors included" do
    result = described_class.failure(StandardError.new("boom"))

    expect(result).to be_frozen
    expect(result.errors).to be_frozen
  end
end
