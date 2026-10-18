# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Domains API", type: :request do
  let(:server) { create(:server) }
  let(:credential) { create(:credential, server: server) }
  let(:headers) { { "x-server-api-key" => credential.key, "content-type" => "application/json" } }

  describe "authentication" do
    it "returns a 401 when no key is provided" do
      get "/api/v1/domains"
      expect(response.status).to eq 401
      expect(JSON.parse(response.body)["error"]["code"]).to eq "AccessDenied"
    end

    it "returns a 401 when the key is not valid" do
      get "/api/v1/domains", headers: { "x-server-api-key" => "invalid" }
      expect(response.status).to eq 401
      expect(JSON.parse(response.body)["error"]["code"]).to eq "InvalidServerAPIKey"
    end

    it "returns a 403 when the server is suspended" do
      suspended_server = create(:server, :suspended)
      suspended_credential = create(:credential, server: suspended_server)
      get "/api/v1/domains", headers: { "x-server-api-key" => suspended_credential.key }
      expect(response.status).to eq 403
      expect(JSON.parse(response.body)["error"]["code"]).to eq "ServerSuspended"
    end
  end

  describe "GET /api/v1/domains" do
    it "returns only the domains owned by the authenticated server" do
      create(:domain, owner: server, name: "b.example.com")
      create(:domain, owner: server, name: "a.example.com")
      create(:domain, name: "other.example.com") # owned by another organization
      get "/api/v1/domains", headers: headers
      expect(response.status).to eq 200
      expect(JSON.parse(response.body).map { |d| d["name"] }).to eq ["a.example.com", "b.example.com"]
    end
  end

  describe "POST /api/v1/domains" do
    it "creates a domain with the DNS verification method" do
      post "/api/v1/domains", headers: headers, params: { name: "example.com", verification_method: "DNS" }.to_json
      expect(response.status).to eq 201
      body = JSON.parse(response.body)["domain"]
      expect(body).to include("name" => "example.com", "verified" => false, "verification_method" => "DNS")
      expect(body["verification"]["dns_txt_value"]).to be_present
      expect(body["records"]["dkim"]["value"]).to match(/\Av=DKIM1;/)
      expect(server.domains.find_by(name: "example.com")).to be_present
    end

    it "defaults the verification method to DNS" do
      post "/api/v1/domains", headers: headers, params: { name: "example.com" }.to_json
      expect(response.status).to eq 201
      expect(JSON.parse(response.body)["domain"]["verification_method"]).to eq "DNS"
    end

    it "returns a 422 when the name is missing" do
      post "/api/v1/domains", headers: headers, params: { verification_method: "DNS" }.to_json
      expect(response.status).to eq 422
      expect(JSON.parse(response.body)["error"]["code"]).to eq "ValidationFailed"
    end

    it "returns a 422 when the domain already exists" do
      create(:domain, owner: server, name: "example.com")
      post "/api/v1/domains", headers: headers, params: { name: "example.com" }.to_json
      expect(response.status).to eq 422
      expect(JSON.parse(response.body)["error"]["errors"]).to include("Name is already added")
    end
  end

  describe "GET /api/v1/domains/:uuid" do
    it "returns the domain" do
      domain = create(:domain, owner: server)
      get "/api/v1/domains/#{domain.uuid}", headers: headers
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["domain"]["uuid"]).to eq domain.uuid
    end

    it "returns a 404 for a domain owned by another server" do
      domain = create(:domain)
      get "/api/v1/domains/#{domain.uuid}", headers: headers
      expect(response.status).to eq 404
      expect(JSON.parse(response.body)["error"]["code"]).to eq "DomainNotFound"
    end
  end

  describe "DELETE /api/v1/domains/:uuid" do
    it "deletes the domain" do
      domain = create(:domain, owner: server)
      expect do
        delete "/api/v1/domains/#{domain.uuid}", headers: headers
      end.to change { Domain.exists?(domain.id) }.from(true).to(false)
      expect(response.status).to eq 204
    end

    it "returns a 404 for a domain owned by another server" do
      domain = create(:domain)
      delete "/api/v1/domains/#{domain.uuid}", headers: headers
      expect(response.status).to eq 404
    end
  end

  describe "POST /api/v1/domains/:uuid/verify" do
    let(:domain) { create(:domain, :unverified, owner: server, verification_method: "DNS") }
    let(:resolver) { instance_double(DNSResolver) }

    before do
      allow(DNSResolver).to receive(:for_domain).with(domain.name).and_return(resolver)
    end

    context "when the DNS TXT record is present" do
      before do
        allow(resolver).to receive(:txt).with(domain.name).and_return([domain.dns_verification_string])
      end

      it "verifies the domain" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers
        expect(response.status).to eq 200
        expect(JSON.parse(response.body)["domain"]["verified"]).to be true
        expect(domain.reload.verified?).to be true
      end
    end

    context "when the DNS TXT record is missing" do
      before do
        allow(resolver).to receive(:txt).with(domain.name).and_return([])
      end

      it "returns a 422" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers
        expect(response.status).to eq 422
        expect(JSON.parse(response.body)["error"]["code"]).to eq "VerificationFailed"
      end
    end

    context "when the domain is already verified" do
      let(:domain) { create(:domain, owner: server) }

      it "returns a 422" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers
        expect(response.status).to eq 422
        expect(JSON.parse(response.body)["error"]["code"]).to eq "AlreadyVerified"
      end
    end

    context "when using email verification" do
      let(:domain) { create(:domain, :unverified, owner: server, verification_method: "Email") }

      it "sends a verification email" do
        expect do
          post "/api/v1/domains/#{domain.uuid}/verify",
               headers: headers,
               params: { email_address: "admin@#{domain.parent_domains.first}" }.to_json
        end.to change { ActionMailer::Base.deliveries.size }.by(1)
        expect(response.status).to eq 200
      end

      it "returns a 422 when the email address is not valid for the domain" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers, params: { email_address: "nope@example.org" }.to_json
        expect(response.status).to eq 422
        expect(JSON.parse(response.body)["error"]["code"]).to eq "InvalidEmailAddress"
      end

      it "returns a 400 when neither an email address nor a code is provided" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers
        expect(response.status).to eq 400
        expect(JSON.parse(response.body)["error"]["code"]).to eq "ParameterError"
      end

      it "verifies the domain with the correct code" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers, params: { code: domain.verification_token }.to_json
        expect(response.status).to eq 200
        expect(domain.reload.verified?).to be true
      end

      it "returns a 422 with an incorrect code" do
        post "/api/v1/domains/#{domain.uuid}/verify", headers: headers, params: { code: "999999" }.to_json
        expect(response.status).to eq 422
        expect(JSON.parse(response.body)["error"]["code"]).to eq "InvalidVerificationCode"
      end
    end
  end

  describe "POST /api/v1/domains/:uuid/check" do
    let(:domain) { create(:domain, :unverified, owner: server) }
    let(:resolver) { instance_double(DNSResolver) }

    before do
      allow(DNSResolver).to receive(:for_domain).with(domain.name).and_return(resolver)
      allow(resolver).to receive(:txt).with(domain.name).and_return([domain.spf_record])
      allow(resolver).to receive(:txt).with("#{domain.dkim_record_name}.#{domain.name}").and_return([domain.dkim_record])
      allow(resolver).to receive(:mx).with(domain.name).and_return([])
      allow(resolver).to receive(:cname).and_return([])
    end

    it "returns the record statuses" do
      post "/api/v1/domains/#{domain.uuid}/check", headers: headers
      expect(response.status).to eq 200
      body = JSON.parse(response.body)["domain"]
      expect(body["statuses"]["spf"]["status"]).to eq "OK"
      expect(body["statuses"]["dkim"]["status"]).to eq "OK"
      expect(body["dns_ok"]).to be true
    end
  end

  describe "POST /api/v1/domains/:uuid/regenerate_dkim" do
    context "when the current DKIM key is verified" do
      let(:domain) { create(:domain, owner: server, dkim_status: "OK") }

      it "creates a pending key" do
        post "/api/v1/domains/#{domain.uuid}/regenerate_dkim", headers: headers
        expect(response.status).to eq 200
        expect(JSON.parse(response.body)["domain"]["pending_dkim"]).to be_present
        expect(domain.reload.pending_dkim_key?).to be true
      end

      it "returns a 422 when a key change is already in progress" do
        domain.regenerate_dkim_key!
        post "/api/v1/domains/#{domain.uuid}/regenerate_dkim", headers: headers
        expect(response.status).to eq 422
        expect(JSON.parse(response.body)["error"]["code"]).to eq "DkimChangeInProgress"
      end
    end

    context "when the current DKIM key is not verified" do
      let(:domain) { create(:domain, owner: server, dkim_status: "Missing") }

      it "replaces the active key immediately" do
        original_key = domain.dkim_private_key
        post "/api/v1/domains/#{domain.uuid}/regenerate_dkim", headers: headers
        expect(response.status).to eq 200
        expect(domain.reload.dkim_private_key).to_not eq original_key
        expect(domain.pending_dkim_key?).to be false
      end
    end
  end

  describe "POST /api/v1/domains/:uuid/cancel_dkim_regeneration" do
    let(:domain) { create(:domain, owner: server, dkim_status: "OK") }

    before do
      domain.regenerate_dkim_key!
    end

    it "discards the pending key" do
      post "/api/v1/domains/#{domain.uuid}/cancel_dkim_regeneration", headers: headers
      expect(response.status).to eq 200
      expect(domain.reload.pending_dkim_key?).to be false
    end
  end
end
