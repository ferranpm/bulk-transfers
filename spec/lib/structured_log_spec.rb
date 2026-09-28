# frozen_string_literal: true

RSpec.describe StructuredLog do
  describe ".format" do
    it "puts the event first, then every field as key=value on one line" do
      line = described_class.format("bulk_transfer.accepted", bank_account_id: 1, transfer_count: 3, duration_ms: 12)

      expect(line).to eq("event=bulk_transfer.accepted bank_account_id=1 transfer_count=3 duration_ms=12")
    end

    it "quotes values that contain spaces" do
      line = described_class.format("bulk_transfer.rejected", message: "Insufficient funds")

      expect(line).to eq('event=bulk_transfer.rejected message="Insufficient funds"')
    end

    it "escapes quotes and newlines so an entry stays on one line" do
      line = described_class.format("bulk_transfer.unavailable", message: %(lock "timeout"\nretry))

      expect(line).to eq('event=bulk_transfer.unavailable message="lock \"timeout\"\nretry"')
    end

    it "renders a blank value as an empty quoted string" do
      line = described_class.format("bulk_transfer.rejected", reason: nil)

      expect(line).to eq('event=bulk_transfer.rejected reason=""')
    end
  end

  describe ".info" do
    it "writes the formatted line to the Rails logger at info level" do
      allow(Rails.logger).to receive(:info)

      described_class.info("bulk_transfer.replayed", bulk_transfer_id: 7)

      expect(Rails.logger).to have_received(:info).with("event=bulk_transfer.replayed bulk_transfer_id=7")
    end
  end
end
