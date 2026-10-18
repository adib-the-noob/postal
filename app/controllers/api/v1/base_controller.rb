# frozen_string_literal: true

module API
  module V1
    # The base controller for the versioned REST API. It authenticates requests
    # using the same server API key as the legacy API (X-Server-API-Key) but,
    # unlike the legacy API, it returns meaningful HTTP status codes alongside
    # a JSON body.
    #
    # Errors are rendered as a JSON object under the `error` key:
    #
    #   { "error": { "code": "DomainNotFound", "message": "..." } }
    #
    class BaseController < ActionController::Base

      skip_before_action :set_browser_id
      skip_before_action :verify_authenticity_token

      before_action :authenticate_as_server

      private

      # Authenticate the request using the X-Server-API-Key header. The key must
      # belong to an API credential of a server which is not suspended. On
      # success the credential is stored in @current_credential and its usage
      # time is updated. Otherwise a 401 or 403 response is rendered and the
      # action is halted.
      #
      # @return [void]
      def authenticate_as_server
        key = request.headers["X-Server-API-Key"]
        if key.blank?
          render_error "AccessDenied", message: "Must be authenticated as a server.", status: :unauthorized
          return
        end

        credential = Credential.where(type: "API", key: key).first
        if credential.nil?
          render_error "InvalidServerAPIKey", message: "The API token provided in X-Server-API-Key was not valid.", status: :unauthorized
          return
        end

        if credential.server.suspended?
          render_error "ServerSuspended", message: "This server is suspended.", status: :forbidden
          return
        end

        credential.use
        @current_credential = credential
      end

      # The server that owns the authenticated credential. All resources are
      # scoped through this to ensure tenant isolation.
      #
      # @return [Server]
      def current_server
        @current_credential.server
      end

      # Render an error response.
      #
      # @param [String] code
      # @param [String, nil] message
      # @param [Symbol] status
      # @param [Hash] extra
      # @return [void]
      def render_error(code, status:, message: nil, **extra)
        render json: { error: { code: code, message: message }.compact.merge(extra) }, status: status
      end

    end
  end
end
