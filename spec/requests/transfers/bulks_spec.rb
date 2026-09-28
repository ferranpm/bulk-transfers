# frozen_string_literal: true

RSpec.describe "POST /transfers/bulk", type: :request do
  def post_bulk(body, idempotency_key: "key-1", content_type: "application/json")
    headers = { "CONTENT_TYPE" => content_type }
    headers["Idempotency-Key"] = idempotency_key unless idempotency_key.nil?
    post "/transfers/bulk", params: body.is_a?(String) ? body : JSON.generate(body), headers:
  end

  def sample(name) = JSON.parse(file_fixture("#{name}.json").read)

  let(:sample1) { sample("sample1") }
  let(:seeded_account) { BankAccount.find_by!(iban: "FR10474608000002006107XXXXX", bic: "OIVUSCLQXXX") }

  before { Rails.application.load_seed }

  context "with sample1.json, which the seeded balance covers" do
    it "returns 201 with the bulk transfer and its credit transfers in request order" do
      post_bulk(sample1)

      expect(response).to have_http_status(:created)
      bulk_transfer = response.parsed_body.fetch("bulk_transfer")
      expect(bulk_transfer).to include("id" => BulkTransfer.sole.id,
                                       "transfer_count" => 3,
                                       "total_amount_cents" => 6_225_150)
      expect(Time.iso8601(bulk_transfer.fetch("created_at"))).to be_within(1.minute).of(Time.current)
      expect(bulk_transfer.fetch("credit_transfers").map { it.except("id") }).to eq(
        [
          { "amount_cents" => 1_450,
            "amount_currency" => "EUR",
            "counterparty_name" => "Bip Bip",
            "counterparty_iban" => "EE383680981021245685",
            "counterparty_bic" => "CRLYFRPPTOU",
            "description" => "Wonderland/4410" },
          { "amount_cents" => 6_123_800,
            "amount_currency" => "EUR",
            "counterparty_name" => "Wile E Coyote",
            "counterparty_iban" => "DE9935420810036209081725212",
            "counterparty_bic" => "ZDRPLBQI",
            "description" => "//TeslaMotors/Invoice/12" },
          { "amount_cents" => 99_900,
            "amount_currency" => "EUR",
            "counterparty_name" => "Bugs Bunny",
            "counterparty_iban" => "FR0010009380540930414023042",
            "counterparty_bic" => "RNJZNTMC",
            "description" => "2020 09 24/2020 09 25/GoldenCarrot/" }
        ]
      )
      expect_ledger_invariants!
    end

    it "debits the seeded account" do
      post_bulk(sample1)

      expect(seeded_account.balance_cents).to eq(10_000_000 - 6_225_150)
      expect_ledger_invariants!
    end
  end

  context "with sample2.json, which exceeds the seeded balance" do
    it "returns 422 insufficient_funds with the amounts and changes nothing" do
      sample2 = sample("sample2")

      expect { post_bulk(sample2) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        "error" => { "code" => "insufficient_funds",
                     "message" => "Insufficient funds",
                     "details" => { "required_amount_cents" => 10_648_216, "available_balance_cents" => 10_000_000 } }
      )
      expect_ledger_invariants!
    end
  end

  context "when the same key is sent again with the same body" do
    it "returns 200 with the original 201 body and moves no money" do
      post_bulk(sample1)
      original_body = response.parsed_body

      expect { post_bulk(sample1) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(original_body)
      expect_ledger_invariants!
    end
  end

  context "when the same key is sent again with a different body" do
    it "returns 422 idempotency_key_reused and changes nothing" do
      post_bulk(sample1)
      sample1["credit_transfers"].first["amount"] = "14.51"

      expect { post_bulk(sample1) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("idempotency_key_reused")
      expect_ledger_invariants!
    end
  end

  context "without an Idempotency-Key header" do
    it "returns 400 missing_idempotency_key, before looking at the body" do
      expect { post_bulk("{not json", idempotency_key: nil) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("missing_idempotency_key")
    end
  end

  context "with a blank Idempotency-Key header" do
    it "returns 400 missing_idempotency_key" do
      expect { post_bulk(sample1, idempotency_key: "   ") }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("missing_idempotency_key")
    end
  end

  context "with an Idempotency-Key header longer than 255 characters" do
    it "returns 400 invalid_idempotency_key" do
      expect { post_bulk(sample1, idempotency_key: "k" * 256) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_idempotency_key")
    end
  end

  context "with an Idempotency-Key header of exactly 255 characters" do
    it "accepts the request" do
      post_bulk(sample1, idempotency_key: "k" * 255)

      expect(response).to have_http_status(:created)
      expect_ledger_invariants!
    end
  end

  context "with malformed JSON" do
    it "returns 400 invalid_json and changes nothing" do
      expect { post_bulk('{"organization_iban": ') }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_json")
    end
  end

  context "with a Content-Type that is not JSON" do
    it "returns 400 invalid_json and changes nothing" do
      expect { post_bulk(JSON.generate(sample1), content_type: "text/plain") }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_json")
    end
  end

  context "with an amount sent as a JSON number" do
    it "returns 422 validation_failed pointing at the amount" do
      sample1["credit_transfers"].first["amount"] = 14.5

      expect { post_bulk(sample1) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        "error" => { "code" => "validation_failed",
                     "message" => ValidationFailedError.default_message,
                     "details" => [{ "index" => 0, "field" => "amount", "issue" => "must_be_a_string" }] }
      )
    end
  end

  context "with a NUL character in a free-text field, which PostgreSQL text can't store" do
    it "returns 422 validation_failed instead of failing on insert" do
      sample1["credit_transfers"].first["counterparty_name"] = "Bip\u0000Bip"

      expect { post_bulk(sample1) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "details")).to eq(
        [{ "index" => 0, "field" => "counterparty_name", "issue" => "invalid_characters" }]
      )
    end
  end

  context "with several invalid fields" do
    it "returns 422 validation_failed listing every problem" do
      body = sample1.merge("organization_bic" => "nope")
      body["credit_transfers"][2]["currency"] = "USD"

      expect { post_bulk(body) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "details")).to contain_exactly(
        { "field" => "organization_bic", "issue" => "invalid_format" },
        { "index" => 2, "field" => "currency", "issue" => "unsupported_currency" }
      )
    end
  end

  context "with unknown fields" do
    it "ignores them" do
      body = sample1.merge("callback_url" => "https://example.test")
      body["credit_transfers"].first["priority"] = "urgent"

      post_bulk(body)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("bulk_transfer", "credit_transfers").first.keys).not_to include("priority")
      expect_ledger_invariants!
    end
  end

  context "when no account matches the IBAN and BIC" do
    it "returns 422 account_not_found and changes nothing" do
      body = sample1.merge("organization_bic" => "CRLYFRPPTOU")

      expect { post_bulk(body) }.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("account_not_found")
    end
  end

  context "when the account lock is held elsewhere past the lock timeout", :concurrency do
    it "returns 503 service_unavailable with Retry-After and changes nothing" do
      expect do
        while_account_locked_elsewhere(seeded_account) do
          with_lock_timeout("50ms") { post_bulk(sample1) }
        end
      end.not_to(change { ledger_snapshot })

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("1")
      expect(response.parsed_body.dig("error", "code")).to eq("service_unavailable")
      expect_ledger_invariants!
    end
  end
end
