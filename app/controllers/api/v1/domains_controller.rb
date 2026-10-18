# frozen_string_literal: true

module API
  module V1
    # Manage the domains owned by the authenticated server over the REST API.
    #
    # Domains are always created under (and scoped to) the server that owns the
    # API key used to make the request. All responses include the DNS records
    # which need to be published and the current verification/DNS status of the
    # domain.
    #
    class DomainsController < BaseController

      before_action :find_domain, only: [:show, :destroy, :verify, :check, :regenerate_dkim, :cancel_dkim_regeneration]

      # List all domains owned by the server.
      #
      #   URL:        GET /api/v1/domains
      #
      #   Response:   200 - An array of domain objects
      #
      def index
        render json: current_server.domains.order(:name).map { |domain| domain_hash(domain) }, status: :ok
      end

      # Return a single domain.
      #
      #   URL:        GET /api/v1/domains/:uuid
      #
      #   Response:   200 - An object containing the domain
      #               404 - When the domain does not exist for this server
      #
      def show
        render json: { domain: domain_hash(@domain) }, status: :ok
      end

      # Create (onboard) a new domain for the server.
      #
      #   URL:            POST /api/v1/domains
      #
      #   Parameters:     name                  => REQ: The domain name to add
      #                   verification_method   => The method used to verify the domain
      #                                            (DNS or Email). Defaults to DNS.
      #
      #   Response:       201 - An object containing the new domain
      #                   422 - When the domain is not valid
      #
      def create
        domain = current_server.domains.build(
          name: params[:name],
          verification_method: params[:verification_method].presence || "DNS"
        )

        if domain.save
          render json: { domain: domain_hash(domain) }, status: :created
        else
          render_error "ValidationFailed",
                       message: "The domain could not be created.",
                       status: :unprocessable_entity,
                       errors: domain.errors.full_messages
        end
      end

      # Delete a domain.
      #
      #   URL:        DELETE /api/v1/domains/:uuid
      #
      #   Response:   204 - When the domain has been removed
      #               404 - When the domain does not exist for this server
      #
      def destroy
        @domain.destroy
        head :no_content
      end

      # Verify ownership of a domain.
      #
      #   URL:            POST /api/v1/domains/:uuid/verify
      #
      #   Parameters:     email_address   => For the Email method, the address to send
      #                                      the verification code to
      #                   code            => For the Email method, the code which was
      #                                      received by e-mail
      #
      #   Response:       200 - An object containing the domain
      #                   404 - When the domain does not exist for this server
      #                   422 - When the domain cannot be verified
      #
      def verify
        if @domain.verified?
          render_error "AlreadyVerified", message: "#{@domain.name} has already been verified.", status: :unprocessable_entity
          return
        end

        case @domain.verification_method
        when "DNS"
          if @domain.verify_with_dns
            render json: { domain: domain_hash(@domain) }, status: :ok
          else
            render_error "VerificationFailed",
                         message: "We couldn't verify your domain. Please check the TXT record has been added correctly.",
                         status: :unprocessable_entity
          end
        when "Email"
          verify_with_email
        end
      end

      # Check the DNS records for a domain.
      #
      #   URL:        POST /api/v1/domains/:uuid/check
      #
      #   Response:   200 - An object containing the domain and its record statuses
      #               404 - When the domain does not exist for this server
      #
      def check
        @domain.check_dns(:manual)
        render json: { domain: domain_hash(@domain) }, status: :ok
      end

      # Generate a new DKIM key for a domain. If the current key is in use, the
      # new key is stored as a pending key until its DNS record has been published.
      #
      #   URL:        POST /api/v1/domains/:uuid/regenerate_dkim
      #
      #   Response:   200 - An object containing the domain
      #               404 - When the domain does not exist for this server
      #               422 - When a DKIM key change is already in progress
      #
      def regenerate_dkim
        if @domain.pending_dkim_key?
          render_error "DkimChangeInProgress",
                       message: "A DKIM key change is already in progress for #{@domain.name}.",
                       status: :unprocessable_entity
          return
        end

        @domain.regenerate_dkim_key!
        render json: { domain: domain_hash(@domain) }, status: :ok
      end

      # Discard a pending DKIM key change.
      #
      #   URL:        POST /api/v1/domains/:uuid/cancel_dkim_regeneration
      #
      #   Response:   200 - An object containing the domain
      #               404 - When the domain does not exist for this server
      #
      def cancel_dkim_regeneration
        @domain.cancel_pending_dkim_key!
        render json: { domain: domain_hash(@domain) }, status: :ok
      end

      private

      def find_domain
        @domain = current_server.domains.find_by(uuid: params[:uuid])
        return if @domain

        render_error "DomainNotFound", message: "The requested domain could not be found.", status: :not_found
      end

      def verification_hash(domain)
        return nil if domain.verified?

        {
          method: domain.verification_method,
          token: domain.verification_token,
          dns_txt_name: domain.name,
          dns_txt_value: domain.dns_verification_string
        }
      end

      def verify_with_email
        if params[:code].present?
          if @domain.verification_token == params[:code].to_s.strip
            @domain.mark_as_verified
            render json: { domain: domain_hash(@domain) }, status: :ok
          else
            render_error "InvalidVerificationCode", message: "Invalid verification code.", status: :unprocessable_entity
          end
        elsif params[:email_address].present?
          unless @domain.verification_email_addresses.include?(params[:email_address])
            render_error "InvalidEmailAddress", message: "The email address is not a valid verification address for this domain.", status: :unprocessable_entity
            return
          end

          AppMailer.verify_domain(@domain, params[:email_address], current_server.organization.owner).deliver
          render json: { domain: domain_hash(@domain), message: "Verification email sent." }, status: :ok
        else
          render_error "ParameterError", message: "Provide `email_address` to send a code or `code` to verify.", status: :bad_request
        end
      end

      def domain_hash(domain)
        {
          uuid: domain.uuid,
          name: domain.name,
          verified: domain.verified?,
          verified_at: domain.verified_at&.to_f,
          verification_method: domain.verification_method,
          dns_checked_at: domain.dns_checked_at&.to_f,
          dns_ok: domain.dns_checked? ? domain.dns_ok? : nil,
          outgoing: domain.outgoing,
          incoming: domain.incoming,
          verification: verification_hash(domain),
          records: {
            spf: { name: domain.name, type: "TXT", value: domain.spf_record },
            dkim: { name: "#{domain.dkim_record_name}.#{domain.name}", type: "TXT", value: domain.dkim_record },
            mx: Postal::Config.dns.mx_records,
            return_path: { name: domain.return_path_domain, type: "CNAME", value: Postal::Config.dns.return_path_domain }
          },
          statuses: {
            spf: { status: domain.spf_status, error: domain.spf_error },
            dkim: { status: domain.dkim_status, error: domain.dkim_error },
            mx: { status: domain.mx_status, error: domain.mx_error },
            return_path: { status: domain.return_path_status, error: domain.return_path_error }
          },
          pending_dkim: domain.pending_dkim_key? ? { name: domain.pending_dkim_record_name, value: domain.pending_dkim_record } : nil
        }
      end

    end
  end
end
